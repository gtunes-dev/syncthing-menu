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

    init(settings: Settings, appSource: UpdateSource, syncthingSource: UpdateSource) {
        self.settings = settings
        self.appSource = appSource
        self.syncthingSource = syncthingSource
    }

    /// Show the settings window, creating it on first use and re-focusing it
    /// thereafter (single instance).
    func show() {
        if window == nil {
            let root = SettingsView(settings: settings,
                                    appSource: appSource,
                                    syncthingSource: syncthingSource)
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Syncthing Menu Settings"
            newWindow.styleMask = [.titled, .closable]   // fixed-size settings panel
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
