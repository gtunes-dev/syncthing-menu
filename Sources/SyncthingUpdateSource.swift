import Foundation

/// The Syncthing update channel: an `UpdateSource` whose mechanism is the daemon's
/// REST API. It is available while the daemon is running (given its base URL + API
/// key) and gates major updates — Syncthing sequences a pending minor ahead of a
/// major (`majorNewer` only goes true once no minor is pending), so a major surfaces
/// alone and waits for explicit consent.
final class SyncthingUpdateSource: UpdateSource {
    /// Run after an upgrade settles so the app re-roots the daemon supervisor onto the
    /// canonical `syncthing` (fresh disclaim) instead of the renamed `syncthing.old`.
    var onUpgradeApplied: (() -> Void)?

    private var api: SyncthingAPI?

    /// Upper bound (seconds) on waiting for a self-upgrade to settle — the daemon
    /// downloads the new binary from upgrades.syncthing.net, swaps it, and restarts its
    /// worker. We re-root regardless once this elapses, so it only needs to be generous.
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
    private static func displayVersion(_ raw: String) -> String {
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
    override func applyUpdate(userInitiated: Bool) async throws {
        guard let api else { throw SyncthingAPI.APIError.badURL }
        // Raw-to-raw comparison, independent of the display normalization.
        let from = try? await api.systemVersion()
        // The daemon downloads + SHA-verifies the new binary, renames the running
        // `syncthing` to `syncthing.old`, writes the new one, and restarts its worker
        // (its monitor keeps our process alive). Wait for it to come up on the new
        // version before re-rooting.
        try await api.performUpgrade()
        let deadline = Date().addingTimeInterval(upgradeSettleTimeout)
        while Date() < deadline {
            if let version = try? await api.systemVersion(), version != from { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    override func didApplyUpdate() {
        // Re-root the supervisor onto the canonical `syncthing`; its reconnect drives a
        // fresh check that settles the card.
        onUpgradeApplied?()
    }
}
