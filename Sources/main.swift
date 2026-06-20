import AppKit

// Entry point. A file named `main.swift` is allowed to contain top-level code,
// which keeps app startup explicit rather than relying on @main / @NSApplicationMain.
let application = NSApplication.shared

// Menu-bar–only app: no Dock icon, no app switcher entry. This mirrors the
// `LSUIElement` flag in Info.plist (belt and suspenders).
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate

application.run()
