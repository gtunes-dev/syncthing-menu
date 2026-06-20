import AppKit

/// Application lifecycle owner. Holds the menu-bar controller today, and will
/// later own the Syncthing subprocess supervisor and the update coordinator.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO: stop the syncthing subprocess cleanly here once SyncthingProcess exists.
    }
}
