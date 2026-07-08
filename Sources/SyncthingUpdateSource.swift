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
    /// Bumped on every connect/disconnect so an in-flight readiness wait can detect it
    /// has been superseded.
    private var connectionToken = 0

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

    /// The daemon is running and reachable. Wait for its REST API, enforce our
    /// no-self-upgrade invariant, then begin the update policy.
    func connect(baseURL: String, apiKey: String) {
        guard let url = URL(string: baseURL) else { return }
        connectionToken &+= 1
        let token = connectionToken
        let api = SyncthingAPI(baseURL: url, apiKey: apiKey)
        self.api = api
        Task { @MainActor in
            // Poll until the daemon answers (up to ~30s), bailing if superseded.
            for _ in 0..<60 {
                guard self.connectionToken == token else { return }
                if (try? await api.systemVersion()) != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard self.connectionToken == token else { return }
            try? await api.setAutoUpgradeIntervalH(0)
            self.makeAvailable()
        }
    }

    /// The daemon stopped or became unreachable.
    func disconnect() {
        connectionToken &+= 1
        api = nil
        makeUnavailable()
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

    override func checkForUpdate() async throws -> UpdateState {
        guard let api else { throw SyncthingAPI.APIError.badURL }
        let info = try await api.upgradeInfo()
        if info.majorNewer { return .available(version: Self.displayVersion(info.latest), isMajor: true) }
        if info.newer { return .available(version: Self.displayVersion(info.latest), isMajor: false) }
        return .upToDate
    }

    override func applyUpdate() async throws {
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
