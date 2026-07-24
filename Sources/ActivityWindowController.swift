import AppKit
import Combine
import SwiftUI

/// Hosts the SwiftUI `ActivityView` in a single reusable AppKit window.
///
/// Chrome design (see also the state table in `ActivityFeed`): a unified
/// title bar carries identity + live state — title "Activity", subtitle the
/// global Syncthing status in the menu's grammar — and the window's verbs as
/// trailing toolbar buttons (Pause⇄Resume, Rescan All, mirroring the menu;
/// Filter is a placeholder for the scoping feature). The content below is
/// pure data. Daemon verbs DISABLE when the daemon isn't running — unlike
/// the menu, which hides its verbs: a toolbar is persistent spatial chrome,
/// and controls that vanish are more disorienting than controls that rest.
///
/// Same agent-app pattern as Settings/About (activate to front, single
/// instance retained across close), but resizable and frame-persistent, so
/// NOT re-centered on every show — the user's placement wins; first open
/// centers once.
///
/// Visibility is the activity feature's on/off switch: `onVisibilityChange`
/// tells the owner when the window opens/closes so the event stream runs only
/// while someone is looking (closed window = zero daemon traffic).
final class ActivityWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private let feed: ActivityFeed
    private let status: SyncthingStatusModel
    private let display = ActivityDisplayModel()
    private var statusSink: AnyCancellable?
    private var filterSink: AnyCancellable?

    /// Fired with `true` on show, `false` when the window closes.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Daemon verbs, wired by the owner to the same handlers as the menu.
    var onRescanAll: (() -> Void)?
    /// `true` = pause all devices, `false` = resume all.
    var onPauseToggle: ((_ pause: Bool) -> Void)?

    private var pauseItem: NSToolbarItem?
    private var rescanItem: NSToolbarItem?
    private var filterItem: NSToolbarItem?
    private var filterButton: NSButton?
    private var pinItem: NSToolbarItem?

    private lazy var filterPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController =
            NSHostingController(rootView: ActivityFilterPopoverView(display: display))
        return popover
    }()

    private static let frameName = "ActivityWindow"
    private static let defaultContentSize = NSSize(width: 640, height: 400)
    private static let keepOnTopKey = "activity.keepOnTop"

    /// The pin toggle's persisted state. An accessory app's normal-level
    /// window drops behind the frontmost regular app's stack whenever a
    /// menu-bar interaction costs us activation (inherent to LSUIElement —
    /// and we deliberately do NOT steal activation back); pinning floats the
    /// window above normal windows so a glance-while-syncing survives menu
    /// excursions. Off by default: always-on-top is an imposition.
    private var keepOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Self.keepOnTopKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.keepOnTopKey) }
    }

    init(feed: ActivityFeed, status: SyncthingStatusModel) {
        self.feed = feed
        self.status = status
    }

    /// `reset` = factory-reset ALL of the window's stateful display aspects
    /// before showing: saved frame → default size, centered; column widths →
    /// defaults (a live table resets via notification); filters → all on;
    /// Keep-on-Top pin → off.
    func show(reset: Bool = false) {
        if reset {
            NSWindow.removeFrame(usingName: Self.frameName)
            ActivityColumnStore.clear()
            display.resetDisplay()
            keepOnTop = false   // applyPin() below applies level + icon
        }
        if window == nil {
            let hosting = NSHostingController(rootView: ActivityView(feed: feed, display: display))
            let newWindow = NSWindow(contentViewController: hosting)
            // The visible identity cluster (icon + name + status) is a custom
            // leading toolbar item; the title itself is hidden but still set —
            // Mission Control and accessibility read it.
            newWindow.title = "Syncthing Menu"
            newWindow.titleVisibility = .hidden
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.preventsApplicationTerminationWhenModal = false
            newWindow.toolbarStyle = .unified
            newWindow.titlebarSeparatorStyle = .automatic
            let toolbar = NSToolbar(identifier: "ActivityToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            newWindow.toolbar = toolbar
            // The identity cluster is a titlebar ACCESSORY, not a toolbar
            // item: accessories render as plain content (no item capsule).
            // The accessory is sized from the view's FRAME at attach time —
            // a fresh hosting view has a zero frame (== invisible accessory),
            // so size it to the SwiftUI content first.
            let headerView = NSHostingView(rootView: ActivityHeaderView(status: status))
            headerView.setFrameSize(headerView.fittingSize)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = headerView
            accessory.layoutAttribute = .leading
            newWindow.addTitlebarAccessoryViewController(accessory)
            newWindow.setContentSize(Self.defaultContentSize)
            if !newWindow.setFrameUsingName(Self.frameName) {
                newWindow.center()
            }
            newWindow.setFrameAutosaveName(Self.frameName)
            newWindow.delegate = self
            window = newWindow
            statusSink = status.$phase
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyStatus() }
            // receive-on-main defers one tick so the model's new values are
            // settled when the icon reads isActive (objectWillChange fires
            // on willSet).
            filterSink = display.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.applyFilterIcon() }
        }
        if reset, let window {
            window.setContentSize(Self.defaultContentSize)
            window.center()
            NotificationCenter.default.post(name: .activityLayoutReset, object: nil)
        }
        applyStatus()
        applyPin()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    /// Reflect the global status in the toolbar: verbs enabled only while the
    /// daemon runs; the pause item is a single state-reflecting toggle, like
    /// the menu's. (The status TEXT lives in the header item's SwiftUI view,
    /// which observes the model itself.)
    private func applyStatus() {
        let running = status.isRunning
        pauseItem?.isEnabled = running
        rescanItem?.isEnabled = running
        let paused = status.isPaused
        pauseItem?.image = NSImage(systemSymbolName: paused ? "play" : "pause",
                                   accessibilityDescription: nil)
        pauseItem?.label = paused ? "Resume All" : "Pause All"
        pauseItem?.toolTip = paused ? "Resume all devices" : "Pause all devices"
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let pause = NSToolbarItem.Identifier("PauseAll")
        static let rescan = NSToolbarItem.Identifier("RescanAll")
        static let filter = NSToolbarItem.Identifier("Filter")
        static let pin = NSToolbarItem.Identifier("KeepOnTop")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Daemon verbs together; Filter and the pin apart at the far edge —
        // acting on Syncthing, scoping the view, and window behavior are
        // different kinds of control. (The identity cluster is a titlebar
        // accessory, not an item.)
        [.flexibleSpace, ItemID.pause, ItemID.rescan, .space, ItemID.filter, ItemID.pin]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.pause:
            let item = makeItem(itemIdentifier, symbol: "pause", label: "Pause All",
                                toolTip: "Pause all devices", action: #selector(togglePause))
            pauseItem = item
            return item
        case ItemID.rescan:
            let item = makeItem(itemIdentifier, symbol: "arrow.clockwise", label: "Rescan All",
                                toolTip: "Rescan all folders", action: #selector(rescanAll))
            rescanItem = item
            return item
        case ItemID.filter:
            // A custom NSButton view (not a bordered image item): the
            // popover needs a real view to anchor to, and the icon swaps to
            // reflect the active state.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(image: Self.filterImage(active: false), target: self,
                                  action: #selector(toggleFilterPopover(_:)))
            button.bezelStyle = .texturedRounded
            button.setButtonType(.momentaryPushIn)
            item.view = button
            item.label = "Filter"
            item.toolTip = "Filter by change source and type"
            filterButton = button
            filterItem = item
            applyFilterIcon()
            return item
        case ItemID.pin:
            let item = makeItem(itemIdentifier, symbol: "pin", label: "Keep on Top",
                                toolTip: "Keep this window above others",
                                action: #selector(togglePin))
            pinItem = item
            return item
        default:
            return nil
        }
    }

    private func makeItem(_ identifier: NSToolbarItem.Identifier, symbol: String,
                          label: String, toolTip: String, action: Selector?) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = toolTip
        item.target = self
        item.action = action
        item.autovalidates = false   // enablement is driven by applyStatus()
        return item
    }

    @objc private func togglePause() {
        onPauseToggle?(!status.isPaused)
    }

    @objc private func rescanAll() {
        onRescanAll?()
    }

    @objc private func toggleFilterPopover(_ sender: NSButton) {
        if filterPopover.isShown {
            filterPopover.performClose(nil)
        } else {
            filterPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }

    private func applyFilterIcon() {
        filterButton?.image = Self.filterImage(active: display.isActive)
    }

    private static func filterImage(active: Bool) -> NSImage {
        NSImage(systemSymbolName: active ? "line.3.horizontal.decrease.circle.fill"
                                         : "line.3.horizontal.decrease",
                accessibilityDescription: active ? "Filter (active)" : "Filter") ?? NSImage()
    }

    @objc private func togglePin() {
        keepOnTop.toggle()
        applyPin()
    }

    /// Reflect the pin state: window level + the pin glyph (filled = pinned).
    private func applyPin() {
        let pinned = keepOnTop
        window?.level = pinned ? .floating : .normal
        pinItem?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                 accessibilityDescription: "Keep on Top")
        pinItem?.toolTip = pinned ? "Stop keeping this window above others"
                                  : "Keep this window above others"
    }
}
