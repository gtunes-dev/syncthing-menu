import AppKit

/// Application lifecycle owner. Holds the menu-bar controller, the settings
/// window, and the update sources. Will later own the Syncthing subprocess
/// supervisor and the real update coordinator.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private let loginItem = LoginItemController()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO: stop the syncthing subprocess cleanly here once SyncthingProcess exists.
    }
}
