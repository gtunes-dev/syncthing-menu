import AppKit

/// Owns the menu-bar status item and its dropdown menu, and reflects the live
/// daemon state (status line + whether "Open Web UI" is available).
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let onOpenSettings: () -> Void

    private var statusMenuItem: NSMenuItem?
    private var webUIItem: NSMenuItem?
    /// The managed daemon's GUI URL when running; nil otherwise.
    private var webUIURL: String?

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        super.init()
        configureButton()
        buildMenu()
        statusItem.menu = menu
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // A template image automatically adapts to light/dark menu bars.
        let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                            accessibilityDescription: "Syncthing Menu")
        image?.isTemplate = true
        button.image = image
    }

    private func buildMenu() {
        // We manage item enablement ourselves.
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "Syncthing: not running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(.separator())

        let webUI = menu.addItem(withTitle: "Open Web UI…",
                                 action: #selector(openWebUI),
                                 keyEquivalent: "o")
        webUI.target = self
        webUI.isEnabled = false   // enabled once the daemon is running (see update)
        webUIItem = webUI

        let settingsItem = menu.addItem(withTitle: "Settings…",
                                        action: #selector(openSettings),
                                        keyEquivalent: ",")
        settingsItem.target = self

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Syncthing Menu",
                                action: #selector(quit),
                                keyEquivalent: "q")
        quit.target = self
    }

    /// Reflect the daemon's current state in the menu. Call on the main thread.
    func update(daemonState: SyncthingProcess.State) {
        switch daemonState {
        case .stopped:
            statusMenuItem?.title = "Syncthing: not running"
            webUIURL = nil
            webUIItem?.isEnabled = false
        case .starting:
            statusMenuItem?.title = "Syncthing: starting…"
            webUIURL = nil
            webUIItem?.isEnabled = false
        case let .running(guiURL):
            statusMenuItem?.title = "Syncthing: running"
            webUIURL = guiURL
            webUIItem?.isEnabled = true
        case let .failed(message):
            statusMenuItem?.title = "Syncthing: \(message)"
            webUIURL = nil
            webUIItem?.isEnabled = false
        }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openWebUI() {
        guard let address = webUIURL, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        // The daemon is stopped via applicationWillTerminate before exit.
        NSApplication.shared.terminate(nil)
    }
}
