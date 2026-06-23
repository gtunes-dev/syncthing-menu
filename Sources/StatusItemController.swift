import AppKit

/// Owns the menu-bar status item and its dropdown menu, and reflects the live
/// daemon state + update availability through the status-item icon and the menu.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let onOpenSettings: () -> Void
    private let onAbout: () -> Void

    private var statusMenuItem: NSMenuItem?
    private var webUIItem: NSMenuItem?
    /// The managed daemon's GUI URL when running; nil otherwise.
    private var webUIURL: String?

    private var daemonState: SyncthingProcess.State = .stopped
    private var updateAvailable = false

    init(onOpenSettings: @escaping () -> Void, onAbout: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onAbout = onAbout
        super.init()
        buildMenu()
        statusItem.menu = menu
        refreshIcon()
    }

    // MARK: - Live state

    /// Reflect the daemon's current state in the menu + icon. Call on the main thread.
    func update(daemonState: SyncthingProcess.State) {
        self.daemonState = daemonState
        switch daemonState {
        case .stopped:
            statusMenuItem?.title = "Syncthing: not running"
            webUIURL = nil; webUIItem?.isEnabled = false
        case .starting:
            statusMenuItem?.title = "Syncthing: starting…"
            webUIURL = nil; webUIItem?.isEnabled = false
        case let .running(guiURL):
            statusMenuItem?.title = "Syncthing: running"
            webUIURL = guiURL; webUIItem?.isEnabled = true
        case let .failed(message):
            statusMenuItem?.title = "Syncthing: \(message)"
            webUIURL = nil; webUIItem?.isEnabled = false
        }
        refreshIcon()
    }

    /// Whether an update (Syncthing or app — the icon doesn't distinguish) is available.
    func setUpdateAvailable(_ available: Bool) {
        guard available != updateAvailable else { return }
        updateAvailable = available
        refreshIcon()
    }

    /// Choose the menu-bar icon from (daemon state, update availability).
    ///
    /// The `syncing` / `paused` icons exist but aren't driven yet — they await live
    /// sync-activity monitoring (the event-stream feature). For now the daemon
    /// lifecycle maps to `idle` (up / starting) or `error` (failed).
    private func refreshIcon() {
        let base: String
        switch daemonState {
        case .running, .starting, .stopped: base = "Idle"
        case .failed: base = "Error"
        }
        let name = "Status\(base)\(updateAvailable ? "Update" : "")"
        let image = NSImage(named: name)
        image?.isTemplate = true
        image?.accessibilityDescription = "Syncthing Menu"
        statusItem.button?.image = image
    }

    // MARK: - Menu

    private func buildMenu() {
        // We manage item enablement ourselves.
        menu.autoenablesItems = false

        let aboutItem = menu.addItem(withTitle: "About Syncthing Menu",
                                     action: #selector(openAbout),
                                     keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(.separator())

        let status = NSMenuItem(title: "Syncthing: not running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(.separator())

        let webUI = menu.addItem(withTitle: "Open Web UI…",
                                 action: #selector(openWebUI),
                                 keyEquivalent: "")
        webUI.target = self
        webUI.isEnabled = false   // enabled once the daemon is running (see update)
        webUIItem = webUI

        let settingsItem = menu.addItem(withTitle: "Settings…",
                                        action: #selector(openSettings),
                                        keyEquivalent: "")
        settingsItem.target = self

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit",
                                action: #selector(quit),
                                keyEquivalent: "")
        quit.target = self
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openAbout() {
        onAbout()
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
