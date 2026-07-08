import AppKit
import Combine

/// Application lifecycle owner. Owns the menu-bar controller, the settings and about
/// windows, the Syncthing subprocess supervisor, and the two update channels.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?
    /// The running daemon's GUI URL (for ad-hoc REST calls like the folder list).
    private var currentGUIURL: String?
    private let loginItem = LoginItemController()
    private let releaseUpdater = ReleaseUpdater()
    private let syncthingProcess = SyncthingProcess()
    /// Live daemon-state feed (pause/sync activity) over the events API — the
    /// single source of truth for daemon-side state while it runs.
    private let syncthingMonitor = SyncthingMonitor()
    private var cancellables = Set<AnyCancellable>()

    // Update channels behind the shared `UpdateSource` policy engine: the app via
    // Sparkle, Syncthing via its REST API.
    private let appUpdateSource = AppUpdateSource(settings: Settings.shared.app)
    private let syncthingUpdateSource = SyncthingUpdateSource(settings: Settings.shared.syncthing)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsController = SettingsWindowController(
            settings: .shared,
            appSource: appUpdateSource,
            syncthingSource: syncthingUpdateSource,
            loginItem: loginItem
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

        // Reflect the daemon's live state in the menu, and connect/disconnect the
        // Syncthing update source + state monitor as the daemon comes up / goes down.
        syncthingProcess.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItemController?.update(daemonState: state)
            switch state {
            case let .running(guiURL):
                self.currentGUIURL = guiURL
                if let key = self.syncthingProcess.apiKey {
                    self.syncthingUpdateSource.connect(baseURL: guiURL, apiKey: key)
                    self.syncthingMonitor.connect(baseURL: guiURL, apiKey: key)
                }
                self.refreshFolders()
            case .stopped, .starting, .failed:
                self.currentGUIURL = nil
                self.syncthingUpdateSource.disconnect()
                self.syncthingMonitor.disconnect()
                self.statusItemController?.update(folders: [])
            }
        }

        // The monitor's snapshot drives the icon's Paused/Syncing marks, the
        // status line, and the Pause⇄Resume toggle label.
        syncthingMonitor.onChange = { [weak self] snapshot in
            self?.statusItemController?.update(allDevicesPaused: snapshot.allDevicesPaused,
                                               syncing: snapshot.syncing)
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
                NSLog("Syncthing binary ready at \(url.path)")
                self.syncthingProcess.start()
            } catch {
                NSLog("Syncthing bootstrap failed: \(error)")
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
    private var currentAPI: SyncthingAPI? {
        guard let urlString = currentGUIURL, let url = URL(string: urlString),
              let key = syncthingProcess.apiKey else { return nil }
        return SyncthingAPI(baseURL: url, apiKey: key)
    }

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
            catch { NSLog("Rescan all failed: \(error)") }
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
                NSLog("\(pause ? "Pause" : "Resume") all devices failed: \(error)")
            }
        }
    }

}
