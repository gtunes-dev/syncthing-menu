import AppKit

/// Owns the menu-bar status item and its dropdown menu.
///
/// For now this renders a mostly static menu. As the app grows it will reflect
/// live Syncthing state (syncing / idle / error) in the icon and status line.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let onOpenSettings: () -> Void

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
        // We manage item enablement ourselves: until we run our own daemon there
        // is nothing legitimate to open or report.
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "Syncthing: not running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let webUI = menu.addItem(withTitle: "Open Web UI…",
                                 action: #selector(openWebUI),
                                 keyEquivalent: "o")
        webUI.target = self
        // Disabled until we manage our own daemon. Its GUI address will come from
        // that daemon's config.xml — never a hardcoded default, which would open
        // whatever unrelated Syncthing happens to be on that port.
        webUI.isEnabled = false

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

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openWebUI() {
        // TODO: open the managed daemon's actual GUI address, read from its
        // config.xml (see design). The item stays disabled until the daemon
        // foundation can supply that address; the constant below is only a
        // placeholder and must not ship as the real source of the URL.
        guard let url = URL(string: "http://127.0.0.1:8384") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        // TODO: stop the syncthing subprocess gracefully before terminating.
        NSApplication.shared.terminate(nil)
    }
}
