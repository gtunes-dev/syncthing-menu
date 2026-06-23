import AppKit
import SwiftUI

/// Hosts the SwiftUI `AboutView` in a single reusable window. Rebuilds the view
/// on each show so the running Syncthing version is current; like the settings
/// window, it activates the app (agent / `LSUIElement`) so the window comes front.
final class AboutWindowController {
    private var window: NSWindow?
    private let syncthingVersion: () -> String?

    init(syncthingVersion: @escaping () -> String?) {
        self.syncthingVersion = syncthingVersion
    }

    func show() {
        let root = AboutView(syncthingVersion: syncthingVersion())
        if let window, let hosting = window.contentViewController as? NSHostingController<AboutView> {
            hosting.rootView = root
            window.layoutIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
        } else {
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "About Syncthing Menu"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.preventsApplicationTerminationWhenModal = false
            newWindow.layoutIfNeeded()
            newWindow.setContentSize(hosting.view.fittingSize)
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
