import Foundation
import Combine

/// The real Syncthing update source, backed by the daemon's REST API. Replaces
/// `MockUpdateSource` for the Syncthing card.
///
/// It is "connected" while the daemon is running (given its base URL + API key)
/// and reports `.unknown` when the daemon is stopped. Update availability maps
/// straight onto the `UpdateState` contract the UI already renders — including the
/// major-vs-minor gating, which Syncthing sequences for us (`majorNewer` only goes
/// true once no minor upgrade is pending).
///
/// Behavior is driven by `Settings`:
/// - while *auto-check* is on, it polls on a timer (plus the check at connect);
/// - after a check that finds a **minor**, it auto-installs only if *auto-install*
///   is effective. Majors are never auto-installed — they wait for explicit consent.
final class SyncthingUpdateSource: UpdateSource {
    private let settings: Settings
    private var api: SyncthingAPI?
    /// Bumped on every connect/disconnect so an in-flight readiness wait can detect
    /// it has been superseded.
    private var connectionEpoch = 0
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Called after an upgrade has been applied and the daemon has restarted onto the
    /// new version. The app uses this to cleanly restart the daemon so its supervisor
    /// re-roots on `syncthing` (fresh disclaim) instead of the renamed `syncthing.old`.
    var onUpgradeApplied: (() -> Void)?

    /// How often to poll for updates while auto-check is enabled.
    private let pollInterval: TimeInterval = 6 * 3600

    init(settings: Settings) {
        self.settings = settings
        super.init(name: "Syncthing")
        // `.receive(on:)` defers past @Published's willSet emission so the handlers
        // read the NEW values. (Reading the property inside a plain sink sees the OLD
        // value, which silently inverted the auto-install toggle.)
        //
        // Start/stop polling live as the auto-check toggle changes. Polling is
        // driven ONLY by auto-check — the auto-install toggle never affects it.
        settings.$syncthingAutoCheckEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePolling() }
            .store(in: &cancellables)
        // When auto-install is turned on, apply a pending MINOR right away.
        settings.$syncthingAutoInstallEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.autoInstallToggled() }
            .store(in: &cancellables)
    }

    /// When *Install automatically* becomes effective while a **minor** update is
    /// already showing, apply it immediately. Majors always require explicit consent
    /// and are never auto-installed here. Does not touch polling.
    private func autoInstallToggled() {
        guard settings.syncthingAutoInstallEffective else { return }
        if case let .available(_, isMajor) = state, !isMajor {
            installAvailable()
        }
    }

    /// Connect to the running daemon: wait for its REST API to come up, enforce our
    /// auto-upgrade invariant via REST (not the config file), do an initial check,
    /// and begin polling if enabled.
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
            self.refresh(autoInstall: true)
            self.updatePolling()
        }
    }

    /// Daemon stopped/unavailable.
    func disconnect() {
        connectionEpoch &+= 1
        api = nil
        stopPolling()
        state = .unknown
    }

    /// Public check (manual button / poll timer). Skipped mid-install so it doesn't
    /// interfere with an upgrade in progress.
    override func checkNow() {
        if case .installing = state { return }
        refresh(autoInstall: true)
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
            // The daemon self-upgrades — it renames the running binary to `syncthing.old`,
            // writes the new `syncthing`, and restarts its worker (its monitor keeps our
            // process alive). Give it a moment to come up on the new version, then ask the
            // app to restart the daemon cleanly so its supervisor re-roots on the canonical
            // `syncthing` (fresh disclaim) instead of staying backed by `syncthing.old`.
            // The restart's reconnect refreshes our state; if no handler is wired, fall back
            // to a plain re-check (autoInstall:false to avoid a retry loop).
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let onUpgradeApplied = self.onUpgradeApplied {
                onUpgradeApplied()
            } else {
                self.refresh(autoInstall: false)
            }
        }
    }

    /// Query upgrade availability and update `state`. When `autoInstall` is true and
    /// a *minor* is available with auto-install effective, kick off the install.
    /// Used directly by the post-install re-check (which must bypass `checkNow`'s
    /// mid-install guard).
    private func refresh(autoInstall: Bool) {
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
                    if autoInstall && self.settings.syncthingAutoInstallEffective {
                        self.installAvailable()
                    }
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

    // MARK: - Polling

    private func updatePolling() {
        if api != nil && settings.syncthingAutoCheckEnabled {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
