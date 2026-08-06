import AppKit

// Entry point. A file named `main.swift` is allowed to contain top-level code,
// which keeps app startup explicit rather than relying on @main / @NSApplicationMain.
let application = NSApplication.shared

// Menu-bar–only app: no Dock icon, no app switcher entry. This mirrors the
// `LSUIElement` flag in Info.plist (belt and suspenders).
application.setActivationPolicy(.accessory)

// A minimal main menu, for key-equivalent routing only — an accessory app never
// shows a menu bar, but AppKit still resolves ⌘X/⌘C/⌘V/⌘A/⌘Z through the Edit
// menu's standard responder-chain actions. Without this, text fields (the
// self-managed port/API-key fields were the app's first) can't cut/copy/paste.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                 keyEquivalent: "a")
let editItem = NSMenuItem()
editItem.submenu = editMenu
let mainMenu = NSMenu()
mainMenu.addItem(editItem)
application.mainMenu = mainMenu

let delegate = AppDelegate()
application.delegate = delegate

application.run()
