import AppKit

/// Application lifecycle owner. Holds the menu-bar controller, the settings
/// window, and the update sources. Will later own the Syncthing subprocess
/// supervisor and the real update coordinator.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private let loginItem = LoginItemController()
    private let releaseUpdater = ReleaseUpdater()
    private let syncthingProcess = SyncthingProcess()

    // Update sources. Mocked for now; the real Syncthing (REST) and app (Sparkle)
    // sources will replace these and conform to the same `UpdateSource` surface.
    private lazy var appUpdateSource: UpdateSource = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return MockUpdateSource(name: "App", currentVersion: version, checkResult: .upToDate)
    }()

    private let syncthingUpdateSource = SyncthingUpdateSource()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsController = SettingsWindowController(
            settings: .shared,
            appSource: appUpdateSource,
            syncthingSource: syncthingUpdateSource,
            loginItem: loginItem
        )
        settingsWindowController = settingsController

        statusItemController = StatusItemController(
            onOpenSettings: { settingsController.show() }
        )

        // Reflect the daemon's live state in the menu, and connect/disconnect the
        // Syncthing update source as the daemon comes up / goes down.
        syncthingProcess.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItemController?.update(daemonState: state)
            switch state {
            case let .running(guiURL):
                if let key = self.syncthingProcess.apiKey {
                    self.syncthingUpdateSource.connect(baseURL: guiURL, apiKey: key)
                }
            case .stopped, .starting, .failed:
                self.syncthingUpdateSource.disconnect()
            }
        }

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
}
