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
        statusItemController = controller

        // Reflect the daemon's live state in the menu, and connect/disconnect the
        // Syncthing update source as the daemon comes up / goes down.
        syncthingProcess.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItemController?.update(daemonState: state)
            switch state {
            case let .running(guiURL):
                self.currentGUIURL = guiURL
                if let key = self.syncthingProcess.apiKey {
                    self.syncthingUpdateSource.connect(baseURL: guiURL, apiKey: key)
                }
                self.refreshFolders()
            case .stopped, .starting, .failed:
                self.currentGUIURL = nil
                self.syncthingUpdateSource.disconnect()
                self.statusItemController?.update(folders: [])
            }
        }

        // After an upgrade is applied, restart the daemon so its supervisor re-roots on
        // the canonical `syncthing` binary (fresh disclaim) instead of the renamed
        // `syncthing.old` that the running monitor would otherwise stay backed by.
        syncthingUpdateSource.onUpgradeApplied = { [weak self] in
            self?.syncthingProcess.restart()
        }

        // Surface "update available" on the menu-bar icon (Syncthing or app — the
        // icon does not distinguish between them).
        Publishers.CombineLatest(syncthingUpdateSource.$state, appUpdateSource.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] syncState, appState in
                let available = Self.isUpdateAvailable(syncState) || Self.isUpdateAvailable(appState)
                self?.statusItemController?.setUpdateAvailable(available)
            }
            .store(in: &cancellables)

        // The app update channel is available from launch, independent of the daemon.
        // (Debug builds keep it off unless SPARKLE_TEST_FEED_URL is set.)
        appUpdateSource.makeAvailable()

        // Bootstrap the binary (download + verify if needed), then launch the
        // managed daemon.
        Task {
            do {
                let url = try await releaseUpdater.bootstrapIfNeeded()
                NSLog("Syncthing binary ready at \(url.path)")
                DispatchQueue.main.async { self.syncthingProcess.start() }
            } catch {
                NSLog("Syncthing bootstrap failed: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncthingProcess.stop()
    }

    private static func isUpdateAvailable(_ state: UpdateState) -> Bool {
        if case .available = state { return true }
        return false
    }

    /// Fetch the daemon's configured folders and push them to the menu. Leaves the
    /// current list untouched on a transient failure; clears it when the daemon
    /// isn't reachable.
    private func refreshFolders() {
        guard let urlString = currentGUIURL, let url = URL(string: urlString),
              let key = syncthingProcess.apiKey else {
            statusItemController?.update(folders: [])
            return
        }
        let api = SyncthingAPI(baseURL: url, apiKey: key)
        Task { @MainActor in
            guard let folders = try? await api.folders() else { return }
            self.statusItemController?.update(folders: folders.map {
                StatusItemController.FolderEntry(name: $0.label.isEmpty ? $0.id : $0.label,
                                                 path: $0.path)
            })
        }
    }

}
