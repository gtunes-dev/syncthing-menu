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

    private lazy var syncthingUpdateSource: UpdateSource =
        MockUpdateSource(name: "Syncthing",
                         currentVersion: "v2.1.1",
                         checkResult: .available(version: "v2.1.2", isMajor: false))

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

        // Reflect the daemon's live state in the menu.
        syncthingProcess.onStateChange = { [weak self] state in
            self?.statusItemController?.update(daemonState: state)
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
