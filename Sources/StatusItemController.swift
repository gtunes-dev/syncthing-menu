import AppKit

/// Owns the menu-bar status item and its dropdown menu.
///
/// For now this just renders a static menu. As the app grows it will reflect
/// live Syncthing state (syncing / idle / error) in the icon and status line.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    override init() {
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
        let status = NSMenuItem(title: "Syncthing: not running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let webUI = menu.addItem(withTitle: "Open Web UI…",
                                 action: #selector(openWebUI),
                                 keyEquivalent: "o")
        webUI.target = self

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Syncthing Menu",
                                action: #selector(quit),
                                keyEquivalent: "q")
        quit.target = self
    }

    @objc private func openWebUI() {
        // TODO: only enable this once the daemon is running; the GUI address is
        // configurable but defaults to http://127.0.0.1:8384.
        guard let url = URL(string: "http://127.0.0.1:8384") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        // TODO: stop the syncthing subprocess gracefully before terminating.
        NSApplication.shared.terminate(nil)
    }
}
