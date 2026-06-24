import AppKit

/// Owns the menu-bar status item and its dropdown menu, and reflects the live
/// daemon state + update availability through the status-item icon and the menu.
///
/// The menu groups this app's items (About, Settings) above the Syncthing items
/// (status, web UI, folders) — matching the Settings and About windows.
final class StatusItemController: NSObject {
    /// One synced folder shown in the Folders submenu.
    struct FolderEntry {
        let name: String
        let path: String
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let foldersMenu = NSMenu()
    private let onOpenSettings: () -> Void
    private let onAbout: () -> Void

    /// Called just before the menu opens, so the owner can refresh live data
    /// (the folder list) before it's shown.
    var onMenuWillOpen: (() -> Void)?

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
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
    }

    // MARK: - Live state

    /// Reflect the daemon's current state in the menu + icon. Call on the main thread.
    func update(daemonState: SyncthingProcess.State) {
        self.daemonState = daemonState
        switch daemonState {
        case .stopped:
            setStatus("Syncthing: not running")
            webUIURL = nil; webUIItem?.isEnabled = false
        case .starting:
            setStatus("Syncthing: starting…")
            webUIURL = nil; webUIItem?.isEnabled = false
        case let .running(guiURL):
            setStatus("Syncthing: running")
            webUIURL = guiURL; webUIItem?.isEnabled = true
        case let .failed(message):
            setStatus("Syncthing: \(message)")
            webUIURL = nil; webUIItem?.isEnabled = false
        }
        refreshIcon()
    }

    /// Replace the Folders submenu contents. Empty → a single, non-selectable
    /// "No Folders" item.
    func update(folders: [FolderEntry]) {
        foldersMenu.removeAllItems()
        guard !folders.isEmpty else {
            let none = foldersMenu.addItem(withTitle: "No Folders", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return
        }
        for folder in folders {
            let item = foldersMenu.addItem(withTitle: folder.name,
                                           action: #selector(openFolder(_:)),
                                           keyEquivalent: "")
            item.target = self
            item.representedObject = folder.path
        }
    }

    /// Whether an update (Syncthing or app — the icon doesn't distinguish) is available.
    func setUpdateAvailable(_ available: Bool) {
        guard available != updateAvailable else { return }
        updateAvailable = available
        refreshIcon()
    }

    /// The status line is informational and non-interactive — a disabled menu item.
    /// AppKit renders disabled items dimmed; the readable-but-non-selectable
    /// alternative needs a custom view, which we avoid for its compat/display
    /// fragility.
    private func setStatus(_ text: String) {
        statusMenuItem?.title = text
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
        foldersMenu.autoenablesItems = false

        // ── Syncthing Menu (this app) ─────────────────────────────────────────
        let aboutItem = menu.addItem(withTitle: "About Syncthing Menu",
                                     action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(.separator())

        let settingsItem = menu.addItem(withTitle: "Syncthing Menu Settings…",
                                        action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self

        menu.addItem(.separator())

        // ── Syncthing (the daemon) ────────────────────────────────────────────
        let status = menu.addItem(withTitle: "Syncthing: not running",
                                  action: nil, keyEquivalent: "")
        status.isEnabled = false   // non-selectable status line (AppKit dims it)
        statusMenuItem = status

        let webUI = menu.addItem(withTitle: "Open Syncthing Web UI",
                                 action: #selector(openWebUI), keyEquivalent: "")
        webUI.target = self
        webUI.isEnabled = false   // enabled once the daemon is running (see update)
        webUIItem = webUI

        let foldersItem = menu.addItem(withTitle: "Folders", action: nil, keyEquivalent: "")
        foldersItem.submenu = foldersMenu
        update(folders: [])        // initial "No Folders" state

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "")
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

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let expanded = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }

    @objc private func quit() {
        // The daemon is stopped via applicationWillTerminate before exit.
        NSApplication.shared.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }
}
