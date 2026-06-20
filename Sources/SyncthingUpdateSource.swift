import Foundation

/// The real Syncthing update source, backed by the daemon's REST API. Replaces
/// `MockUpdateSource` for the Syncthing card.
///
/// It is "connected" while the daemon is running (given its base URL + API key)
/// and reports `.unknown` when the daemon is stopped. Update availability maps
/// straight onto the `UpdateState` contract the UI already renders — including the
/// major-vs-minor gating, which Syncthing sequences for us (`majorNewer` only goes
/// true once no minor upgrade is pending).
final class SyncthingUpdateSource: UpdateSource {
    private var api: SyncthingAPI?
    /// Bumped on every connect/disconnect so an in-flight readiness wait can detect
    /// it has been superseded.
    private var connectionEpoch = 0

    init() {
        super.init(name: "Syncthing")
    }

    /// Connect to the running daemon: wait for its REST API to come up (it isn't
    /// ready the instant the process launches), enforce our auto-upgrade invariant
    /// via REST (not the config file), then do an initial check.
    func connect(baseURL: String, apiKey: String) {
        guard let url = URL(string: baseURL) else { return }
        connectionEpoch &+= 1
        let epoch = connectionEpoch
        let api = SyncthingAPI(baseURL: url, apiKey: apiKey)
        self.api = api
        state = .checking
        Task { @MainActor in
            // Poll until the daemon answers (up to ~30s), bailing if superseded.
            for _ in 0..<60 {
                guard self.connectionEpoch == epoch else { return }
                if (try? await api.systemVersion()) != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard self.connectionEpoch == epoch else { return }
            try? await api.setAutoUpgradeIntervalH(0)
            self.checkNow()
        }
    }

    /// Daemon stopped/unavailable.
    func disconnect() {
        connectionEpoch &+= 1
        api = nil
        state = .unknown
    }

    override func checkNow() {
        guard let api else { state = .unknown; return }
        state = .checking
        Task { @MainActor in
            do {
                let info = try await api.upgradeInfo()
                self.currentVersion = info.running
                if info.majorNewer {
                    self.state = .available(version: info.latest, isMajor: true)
                } else if info.newer {
                    self.state = .available(version: info.latest, isMajor: false)
                } else {
                    self.state = .upToDate
                }
            } catch {
                // TODO (B3c): distinguish a transient connection drop and re-read
                // config.xml to reconnect (self-healing).
                self.state = .unknown
            }
        }
    }

    override func installAvailable() {
        guard let api, case .available = state else { return }
        state = .installing
        Task { @MainActor in
            do {
                try await api.performUpgrade()
            } catch {
                self.state = .unknown
                return
            }
            // The daemon downloads, replaces its binary, and restarts. Give it a
            // moment, then re-check to reflect the new version. (Robust restart
            // handling is B4; self-healing reconnect is B3c.)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.checkNow()
        }
    }
}
