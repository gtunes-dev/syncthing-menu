import AppKit
import Combine
import os

/// Application lifecycle owner. Owns the menu-bar controller, the settings and about
/// windows, the Syncthing subprocess supervisor, and the two update channels.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?
    private let loginItem = LoginItemController()
    /// Folders blocked on permissions, shared with the Settings UI (the FDA
    /// section's alert state). Fed from the monitor's snapshot below.
    private let folderHealth = FolderHealth()
    private let releaseUpdater = ReleaseUpdater()
    private let syncthingProcess = SyncthingProcess()
    /// The session layer: turns process lifecycle + endpoint reachability into a
    /// verified `SyncthingAPI` (or nothing). All REST consumers hang off this.
    private lazy var daemonSession = DaemonSession(endpoints: syncthingProcess)
    /// The API the consumers were last handed — session republishes after a blip
    /// recovery carry the same identity, and only real changes propagate.
    private var lastPublishedAPI: SyncthingAPI?
    /// Live daemon-state feed (pause/sync activity) over the events API — the
    /// single source of truth for daemon-side state while it runs.
    private let syncthingMonitor = SyncthingMonitor()
    private var cancellables = Set<AnyCancellable>()

    // Update channels behind the shared `UpdateSource` policy engine: the app via
    // Sparkle, Syncthing via its REST API.
    private let appUpdateSource = AppUpdateSource(settings: Settings.shared.app)
    private let syncthingUpdateSource = SyncthingUpdateSource(settings: Settings.shared.syncthing)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under the unit-test runner the app is only a test host: skip real startup
        // (status item, Sparkle, daemon bootstrap) — tests build their own fixtures.
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            return
        }

        let settingsController = SettingsWindowController(
            settings: .shared,
            appSource: appUpdateSource,
            syncthingSource: syncthingUpdateSource,
            loginItem: loginItem,
            folderHealth: folderHealth
        )
        settingsWindowController = settingsController

        let aboutController = AboutWindowController(
            syncthingVersion: { [weak self] in self?.syncthingUpdateSource.currentVersion }
        )
        aboutWindowController = aboutController

        let controller = StatusItemController(
            onOpenSettings: { settingsController.show() },
            onAbout: { aboutController.show() }
        )
        controller.onMenuWillOpen = { [weak self] in self?.refreshFolders() }
        controller.onStartSyncthing = { [weak self] in self?.launchDaemon() }
        controller.onRescanAll = { [weak self] in self?.rescanAll() }
        controller.onPauseToggle = { [weak self] pause in self?.setAllDevicesPaused(pause) }
        controller.onUpdateApp = { [weak self] in self?.appUpdateSource.installAvailable() }
        controller.onUpdateSyncthing = { [weak self] in self?.syncthingUpdateSource.installAvailable() }
        statusItemController = controller

        // Reflect the daemon's live state in the menu; the session turns lifecycle
        // into a verified endpoint for every REST consumer (supervision model:
        // Process → Session → consumers, design.md § Process & session supervision).
        syncthingProcess.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItemController?.update(daemonState: state)
            self.daemonSession.processStateChanged(state)
        }

        daemonSession.onChange = { [weak self] sessionState in
            guard let self else { return }
            switch sessionState {
            case let .connected(api):
                // The monitor reconnects on EVERY publish (its poll task ended if
                // it escalated; reseeding is cheap). The update source only sees
                // real identity changes, so a blip recovery on the same endpoint
                // doesn't reset an in-flight install or re-trigger checks.
                self.syncthingMonitor.connect(api: api)
                if api != self.lastPublishedAPI {
                    self.lastPublishedAPI = api
                    self.syncthingUpdateSource.sessionChanged(api: api)
                    self.statusItemController?.update(webUIURL: api.baseURL.absoluteString)
                }
                self.refreshFolders()
            case .unavailable:
                self.lastPublishedAPI = nil
                self.syncthingMonitor.disconnect()
                self.syncthingUpdateSource.sessionChanged(api: nil)
                self.statusItemController?.update(folders: [])
                // The monitor's last snapshot dies with the daemon.
                self.statusItemController?.update(allDevicesPaused: false, syncing: false,
                                                  folderAttention: false)
                self.folderHealth.permissionErrorFolders = []
            case .connecting:
                // Transient (startup discovery or post-suspicion re-verify):
                // consumers keep what they have until it resolves.
                break
            }
        }

        // The monitor doubles as the session's health probe: persistent long-poll
        // failure means the endpoint moved or died — let the session reconcile.
        syncthingMonitor.onEndpointSuspect = { [weak self] in
            self?.daemonSession.endpointSuspect()
        }

        // The monitor's snapshot drives the icon's Paused/Syncing/attention
        // marks, the status line, the Pause⇄Resume toggle label, and the FDA
        // section's alert state in Settings.
        syncthingMonitor.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.statusItemController?.update(
                allDevicesPaused: snapshot.allDevicesPaused,
                syncing: snapshot.syncing,
                folderAttention: !snapshot.permissionErrorFolders.isEmpty)
            self.folderHealth.permissionErrorFolders = snapshot.permissionErrorFolders
        }

        // After an upgrade is applied, restart the daemon so its supervisor re-roots on
        // the canonical `syncthing` binary (fresh disclaim) instead of the renamed
        // `syncthing.old` that the running monitor would otherwise stay backed by.
        syncthingUpdateSource.onUpgradeApplied = { [weak self] in
            self?.syncthingProcess.restart()
        }

        // Surface pending updates in the menu (a direct action item per channel)
        // and on the menu-bar icon (one arrow for either; the tooltip names
        // versions). While one channel installs, the other's item is disabled —
        // installs are serialized app-wide, matching the Settings cards.
        Publishers.CombineLatest3(appUpdateSource.$state, syncthingUpdateSource.$state,
                                  UpdateInstallCoordinator.shared.$installingChannel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appState, syncState, installing in
                let idle = installing == nil
                self?.statusItemController?.update(
                    appUpdate: Self.pendingUpdate(appState, enabled: idle),
                    syncthingUpdate: Self.pendingUpdate(syncState, enabled: idle))
            }
            .store(in: &cancellables)

        // The app update channel is available from launch, independent of the daemon.
        // (Debug builds keep it off unless SPARKLE_TEST_FEED_URL is set.)
        appUpdateSource.makeAvailable()

        launchDaemon()
    }

    /// Bootstrap the binary (download + verify if needed), then launch the
    /// managed daemon. Also the menu's "Start Syncthing" recovery path after a
    /// failure — `SyncthingProcess.start()` no-ops if the daemon is already up.
    private func launchDaemon() {
        Task { @MainActor in
            do {
                let url = try await releaseUpdater.bootstrapIfNeeded()
                Log.app.log("Syncthing binary ready at \(url.path, privacy: .public)")
                self.syncthingProcess.start()
            } catch {
                Log.app.error("Syncthing bootstrap failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncthingProcess.stop()
    }

    private static func pendingUpdate(_ state: UpdateState,
                                      enabled: Bool) -> StatusItemController.PendingUpdate? {
        guard case let .available(version, isMajor) = state else { return nil }
        return .init(version: version, isMajor: isMajor, enabled: enabled)
    }

    /// A REST client for the running daemon, or nil when it isn't reachable.
    private var currentAPI: SyncthingAPI? { daemonSession.api }

    /// Fetch the daemon's configured folders and push them to the menu. Leaves the
    /// current list untouched on a transient failure; clears it when the daemon
    /// isn't reachable.
    private func refreshFolders() {
        guard let api = currentAPI else {
            statusItemController?.update(folders: [])
            return
        }
        Task { @MainActor in
            guard let folders = try? await api.folders() else { return }
            self.statusItemController?.update(folders: folders.map {
                StatusItemController.FolderEntry(name: $0.label.isEmpty ? $0.id : $0.label,
                                                 path: $0.path)
            })
        }
    }

    private func rescanAll() {
        guard let api = currentAPI else { return }
        Task {
            do { try await api.rescanAll() }
            catch { Log.app.error("Rescan all failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Fire the pause/resume call; the resulting state comes back through the
    /// monitor's event stream (within milliseconds), so there is no optimistic
    /// local flip — one source of truth.
    private func setAllDevicesPaused(_ pause: Bool) {
        guard let api = currentAPI else { return }
        Task {
            do {
                if pause {
                    try await api.pauseAllDevices()
                } else {
                    try await api.resumeAllDevices()
                }
            } catch {
                Log.app.error("\(pause ? "Pause" : "Resume", privacy: .public) all devices failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

}
