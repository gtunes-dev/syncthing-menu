import Foundation

/// The Syncthing update channel: an `UpdateSource` whose mechanism is the daemon's
/// REST API. It is available while the daemon is running (given its base URL + API
/// key) and gates major updates — Syncthing sequences a pending minor ahead of a
/// major (`majorNewer` only goes true once no minor is pending), so a major surfaces
/// alone and waits for explicit consent.
final class SyncthingUpdateSource: UpdateSource {
    private var api: SyncthingAPI?

    /// The daemon upgrades and restarts itself in place — its monitor re-execs
    /// onto the canonical `syncthing` (same PID, our supervision and the TCC
    /// disclaim intact; verified live 2026-08-11, incl. FDA on a protected
    /// folder) — so nothing needs restarting on our side and the policy layer
    /// settles the card with a fresh check.
    override var installCompletesInPlace: Bool { true }

    /// Upper bound (seconds) on waiting for a self-upgrade to settle — the daemon
    /// downloads the new binary from upgrades.syncthing.net, swaps it, and restarts.
    /// On timeout we give up waiting and let the settle check report whatever is
    /// actually running, so it only needs to be generous.
    private let upgradeSettleTimeout: TimeInterval = 90

    init(settings: UpdateChannelSettings) {
        super.init(name: "Syncthing", settings: settings,
                   pollInterval: 6 * 3600, gatesMajorUpdates: true)
    }

    override func releaseNotesURL(for version: String) -> URL? {
        ReleaseNotes.syncthing(version: version)
    }

    // MARK: - Daemon lifecycle

    /// Session hand-off: a non-nil API is a session-verified endpoint (the session
    /// owns readiness polling and the autoUpgradeIntervalH=0 invariant), so
    /// availability tracks it directly. Called only on real identity changes and
    /// process-level transitions — NOT on transient `.connecting` blips, so an
    /// in-flight install's settle-wait keeps its epoch across a worker restart.
    func sessionChanged(api: SyncthingAPI?) {
        self.api = api
        if api != nil {
            makeAvailable()
        } else {
            makeUnavailable()
        }
    }

    // MARK: - Mechanism

    /// The daemon's API reports Git-tag-style versions ("v2.1.1"). The "v" is
    /// tag orthography, not part of the version — strip it at this boundary so
    /// every UI surface shows bare semver, matching the app's own
    /// CFBundleShortVersionString convention. (`ReleaseNotes` re-normalizes
    /// when building tag URLs, so links are unaffected.)
    static func displayVersion(_ raw: String) -> String {
        String(raw.drop(while: { $0 == "v" || $0 == "V" }))
    }

    override func fetchVersion() async -> String? {
        (try? await api?.systemVersion()).map(Self.displayVersion)
    }

    /// Availability is determined client-side (`SyncthingReleases`): the daemon
    /// runs with `STNOUPGRADE=1` (no Web UI upgrade banner, no self-upgrades),
    /// which also disables its `GET /rest/system/upgrade`. We fetch the daemon's
    /// own `releasesURL` feed and apply its selection rules, so this check and
    /// the daemon-side `POST` install keep resolving the same release.
    override func checkForUpdate() async throws -> UpdateState {
        guard let api else { throw SyncthingAPI.APIError.badURL }
        let running = try await api.systemVersionInfo()
        let options = try await api.upgradeCheckOptions()
        guard let feedURL = URL(string: options.releasesURL) else {
            throw SyncthingAPI.APIError.badURL
        }
        let releases = try await SyncthingReleases.fetchReleases(from: feedURL)
        let latest = try SyncthingReleases.selectLatestRelease(
            releases, current: running.version,
            upgradeToPreReleases: options.upgradeToPreReleases, arch: running.arch)
        switch SyncthingReleases.compareVersions(latest.tag, running.version) {
        case .majorNewer:
            return .available(version: Self.displayVersion(latest.tag), isMajor: true)
        case .newer:
            return .available(version: Self.displayVersion(latest.tag), isMajor: false)
        default:
            return .upToDate
        }
    }

    /// Same mechanism for user-initiated and automatic installs: there is no
    /// per-update consent UI on this channel (the click is the consent; release
    /// notes live on the card), so `userInitiated` is unused.
    /// Thrown when an upgrade can't be confirmed: the pre-upgrade version was
    /// unreadable (the settle comparison would be unsound) or the daemon never
    /// came up on a new version within the settle window. Routed through the
    /// policy layer's failure path — state resets and the error is logged.
    struct UpgradeSettleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    override func applyUpdate(userInitiated: Bool) async throws {
        guard let api else { throw SyncthingAPI.APIError.badURL }
        // Raw-to-raw comparison, independent of the display normalization. The
        // pre-upgrade version MUST be readable: with `from` nil, the first
        // successful read below would satisfy `version != from` and report a
        // non-upgrade as settled.
        guard let from = try? await api.systemVersion() else {
            throw UpgradeSettleError(message: "Couldn't read the running version before upgrading")
        }
        // The daemon downloads + SHA-verifies the new binary, renames the running
        // `syncthing` to `syncthing.old`, writes the new one, and restarts: the
        // worker exits and the monitor re-execs itself onto the canonical path (our
        // argv[0]), so the process we supervise ends up backed by the NEW binary
        // with the disclaim intact. Wait for it to come up on the new version so
        // the settle check reflects reality. Deliberately NO kill/respawn here:
        // the old re-root shot a healthy just-booted daemon, blew the stop ladder
        // (v2 workers shut down slowly right after boot), SIGKILLed the monitor,
        // and the orphaned worker's DB lock crash-looped the respawn (2026-08-11).
        try await api.performUpgrade()
        Log.updates.log("Syncthing upgrade POST accepted (running \(from, privacy: .public))")
        let started = Date()
        let deadline = started.addingTimeInterval(upgradeSettleTimeout)
        while Date() < deadline {
            // Re-read `self.api` each poll: a config migration can rotate the
            // key or move the GUI port mid-upgrade, and the session hands the
            // fresh endpoint to `sessionChanged` — polling only the pre-POST
            // endpoint would wait out the full timeout against a dead address.
            let current = self.api ?? api
            if let version = try? await current.systemVersion(), version != from {
                Log.updates.log("Syncthing upgrade settled: \(from, privacy: .public) → \(version, privacy: .public) after \(Int(Date().timeIntervalSince(started)))s")
                verifyInstalledBinary()
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // A timeout is a FAILURE. Returning success here would let a
        // persistently failing upgrade re-offer and, with auto-install on,
        // re-POST in a ~90s loop with no backoff and no logged error.
        throw UpgradeSettleError(message: "Syncthing didn't come up on a new version within \(Int(upgradeSettleTimeout))s")
    }

    /// Detection parity with the removed re-root, which re-ran the pinned
    /// Developer-ID verification on the daemon-written binary within seconds of
    /// an upgrade; without this, the next check would wait for the next spawn —
    /// potentially weeks for a menu-bar app. Off-main (SecStaticCode does I/O)
    /// and log-only: the binary has already exec'd, so this is detection, not
    /// prevention — same property the re-root had.
    private func verifyInstalledBinary() {
        DispatchQueue.global(qos: .utility).async {
            do {
                try BinaryVerifier.verifySyncthingBinary(at: ReleaseUpdater.installedBinaryURL)
                Log.updates.log("post-upgrade binary verification passed")
            } catch {
                Log.updates.error("post-upgrade binary verification FAILED: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
