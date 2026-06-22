import AppKit
import SwiftUI

/// Hosts the SwiftUI `SettingsView` in a single reusable AppKit window.
///
/// Because this is a menu-bar agent (`LSUIElement`, no Dock icon), opening the
/// window requires explicitly activating the app so the window comes to the front
/// and can take focus.
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: Settings
    private let appSource: UpdateSource
    private let syncthingSource: UpdateSource
    private let loginItem: LoginItemController

    init(settings: Settings,
         appSource: UpdateSource,
         syncthingSource: UpdateSource,
         loginItem: LoginItemController) {
        self.settings = settings
        self.appSource = appSource
        self.syncthingSource = syncthingSource
        self.loginItem = loginItem
    }

    /// Show the settings window, creating it on first use and re-focusing it
    /// thereafter (single instance).
    func show() {
        if window == nil {
            let root = SettingsView(settings: settings,
                                    appSource: appSource,
                                    syncthingSource: syncthingSource,
                                    loginItem: loginItem)
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Syncthing Menu Settings"
            newWindow.styleMask = [.titled, .closable]   // fixed-size settings panel
            newWindow.isReleasedWhenClosed = false
            newWindow.preventsApplicationTerminationWhenModal = false
            // Force a layout pass and pin the window to the SwiftUI content's
            // resolved size, so the later center() positions a correctly-sized
            // window rather than an intermediate one.
            newWindow.layoutIfNeeded()
            newWindow.setContentSize(hosting.view.fittingSize)
            window = newWindow
        }

        // Center on the active screen each time it's opened. NSWindow.center() is the
        // HIG placement: horizontally centered, biased slightly above vertical center.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
