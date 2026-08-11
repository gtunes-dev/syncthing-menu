import Foundation

/// The Syncthing update channel: an `UpdateSource` whose mechanism is the daemon's
/// REST API. It is available while the daemon is running (given its base URL + API
/// key) and gates major updates — Syncthing sequences a pending minor ahead of a
/// major (`majorNewer` only goes true once no minor is pending), so a major surfaces
/// alone and waits for explicit consent.
final class SyncthingUpdateSource: UpdateSource {
    private var api: SyncthingAPI?

    /// Run after an upgrade settles so the app re-roots the daemon supervisor
    /// (`SyncthingProcess.restart()`): the surviving monitor PID carries the
    /// swap's TCC baggage — during the rename dance its executable path read
    /// `syncthing.old`, and tccd's evaluation of that identity can stick to the
    /// PID, breaking Full Disk Access until relaunch (production 2026-08-11).
    /// The fresh spawn (new PID, fresh disclaim, canonical path) definitively
    /// ends the exposure; the ladder behind it is patient and reaps the whole
    /// process tree, so the just-booted worker can never be orphaned on the
    /// database lock (the original 0.3.4-era failed-relaunch bug).
    var onUpgradeApplied: (() -> Void)?

    /// Whether the daemon is currently scanning or syncing (wired to the live
    /// monitor snapshot). The install briefly waits for idle before POSTing:
    /// the swap's sub-second `syncthing.old` window only bites when file
    /// accesses land inside it, and both observed incidents fired mid-scan.
    /// Nil (unwired, e.g. tests) skips the gate.
    var isDaemonBusy: (() -> Bool)?

    /// Upper bound (seconds) on waiting for a self-upgrade to settle — the daemon
    /// downloads the new binary from upgrades.syncthing.net, swaps it, and restarts
    /// its worker. The re-root runs only after this confirms (or fails loudly), so
    /// it only needs to be generous.
    private let upgradeSettleTimeout: TimeInterval = 90

    /// Upper bound (seconds) on the pre-POST wait for the daemon to go idle.
    /// Bounded so a long sync can't wedge the Update click; on expiry the
    /// install proceeds anyway (logged) — the idle gate is risk reduction,
    /// not a correctness requirement.
    private let quiesceTimeout: TimeInterval = 120

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

    /// Thrown when an upgrade can't be confirmed: the pre-upgrade version was
    /// unreadable (the settle comparison would be unsound) or the daemon never
    /// came up on a new version within the settle window. Routed through the
    /// policy layer's failure path — state resets and the error is logged.
    struct UpgradeSettleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Same mechanism for user-initiated and automatic installs: there is no
    /// per-update consent UI on this channel (the click is the consent; release
    /// notes live on the card), so `userInitiated` is unused.
    override func applyUpdate(userInitiated: Bool) async throws {
        guard let api else { throw SyncthingAPI.APIError.badURL }
        // Raw-to-raw comparison, independent of the display normalization. The
        // pre-upgrade version MUST be readable: with `from` nil, the first
        // successful read below would satisfy `version != from` and report a
        // non-upgrade as settled.
        guard let from = try? await api.systemVersion() else {
            throw UpgradeSettleError(message: "Couldn't read the running version before upgrading")
        }

        // Idle gate: the daemon's upgrade renames the RUNNING binary to
        // `syncthing.old` under a live process tree — a sub-second window in
        // which any synced-folder access is TCC-attributed to `syncthing.old`
        // (no FDA grant → permission prompt, and the poisoned evaluation can
        // stick to the monitor PID). We can't remove the window — the daemon
        // owns the dance, and its hardened download path is the point of using
        // POST — but we choose WHEN it happens: wait briefly for scans/pulls
        // to finish so nothing is touching files when it opens.
        let quiesceDeadline = Date().addingTimeInterval(quiesceTimeout)
        while isDaemonBusy?() == true {
            if Date() >= quiesceDeadline {
                Log.updates.log("Syncthing upgrade: daemon still busy after \(Int(self.quiesceTimeout))s — proceeding anyway")
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // The daemon downloads + SHA-verifies the new binary, renames the running
        // `syncthing` to `syncthing.old`, writes the new one, and restarts its
        // worker. Wait for it to come up on the new version, then didApplyUpdate
        // triggers the re-root. The 0.5s poll keeps the detection latency — part
        // of the swap-to-fresh-PID exposure — small.
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
                Log.updates.log("Syncthing upgrade settled: \(from, privacy: .public) → \(version, privacy: .public) after \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // A timeout is a FAILURE. Returning success here would trigger a
        // pointless re-root and let a persistently failing upgrade re-offer
        // silently — with auto-install on, a ~90s re-POST loop.
        throw UpgradeSettleError(message: "Syncthing didn't come up on a new version within \(Int(upgradeSettleTimeout))s")
    }

    override func didApplyUpdate() {
        // Re-root the supervisor onto a fresh PID (fresh disclaim, canonical
        // path); its reconnect bounce drives a fresh check that settles the
        // card. The freshly spawned daemon also re-runs the pinned Developer-ID
        // verification on the upgraded binary (`prepareLaunch`), seconds after
        // the daemon wrote it.
        onUpgradeApplied?()
    }
}
