import AppKit
import Combine
import SwiftUI

/// Hosts the SwiftUI `ActivityView` in a single reusable AppKit window.
///
/// Chrome design (see also the model doc in `ActivityFeed`): a unified
/// title bar carries identity + live state — title "Activity", subtitle the
/// global Syncthing status in the menu's grammar — and trailing toolbar
/// controls that all act on the WINDOW itself: the name-search field and the
/// Filter popover (both writing into the shared `ActivityDisplayModel`) and
/// the Keep-on-Top pin. The content below is pure data.
///
/// Deliberately NO daemon verbs here (Pause/Rescan removed 2026-08-18,
/// superseding the 0.3.0 mirror-the-menu design): the window is a pure
/// observation instrument, and its chrome follows one grammar — everything
/// in the toolbar scopes or positions the window. Commanding Syncthing is
/// the menu's job, one click away.
///
/// Same agent-app pattern as Settings/About (activate to front, single
/// instance retained across close), but resizable and frame-persistent, so
/// NOT re-centered on every show — the user's placement wins; first open
/// centers once.
///
/// Visibility is one of the feed's two recording inputs: `onVisibilityChange`
/// tells the owner when the window opens/closes, and under the default
/// "while the window is open" policy that is what starts and pauses
/// recording (closed window = zero daemon traffic); under "always" the
/// window is just a view onto a log that records regardless. The log
/// survives close either way — Clear (toolbar, ⌘K) is the only way to
/// empty it.
final class ActivityWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate,
                                      NSSearchFieldDelegate {
    private var window: NSWindow?
    private let feed: ActivityFeed
    /// Feeds the header accessory's live status line (the SwiftUI view
    /// observes it directly — the controller itself no longer reacts to
    /// status changes now that no toolbar item depends on daemon state).
    private let status: SyncthingStatusModel
    private let display = ActivityDisplayModel()
    private var filterSink: AnyCancellable?

    /// Fired with `true` on show, `false` when the window closes.
    var onVisibilityChange: ((Bool) -> Void)?

    private var filterItem: NSToolbarItem?
    private var filterButton: NSButton?
    private var pinItem: NSToolbarItem?
    private var searchItem: NSSearchToolbarItem?

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
            display.resetDisplay()   // filters, search text, and sort
            searchItem?.searchField.stringValue = ""
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
        applyPin()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        // The search text is transient view scoping: every open starts with
        // the whole log in view (the rows themselves persist — see the
        // header comment).
        display.searchText = ""
        searchItem?.searchField.stringValue = ""
        onVisibilityChange?(false)
    }

    // MARK: - Search

    /// One sync point for both search signals (typing via the field
    /// delegate, clear/Return via the action).
    @objc private func searchChanged() {
        display.searchText = searchItem?.searchField.stringValue ?? ""
    }

    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let search = NSToolbarItem.Identifier("Search")
        static let filter = NSToolbarItem.Identifier("Filter")
        static let pin = NSToolbarItem.Identifier("KeepOnTop")
        static let clear = NSToolbarItem.Identifier("Clear")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The view-scoping pair (search, then the Filter popover), the pin,
        // then Clear — every control acts on the window itself. (The
        // identity cluster is a titlebar accessory, not an item.)
        [.flexibleSpace, ItemID.search, ItemID.filter, ItemID.pin, ItemID.clear]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
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
        case ItemID.search:
            // Name search: writes straight into the display model (the view
            // filters live per keystroke). Both signals are wired — the
            // delegate's text-change for typing, the action for the clear
            // button and Return — through one sync point.
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search names"
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged)
            item.label = "Search"
            item.toolTip = "Show only entries whose name contains the text"
            searchItem = item
            return item
        case ItemID.pin:
            let item = makeItem(itemIdentifier, symbol: "pin", label: "Keep on Top",
                                toolTip: "Keep this window above others",
                                action: #selector(togglePin))
            pinItem = item
            return item
        case ItemID.clear:
            return makeItem(itemIdentifier, symbol: "trash", label: "Clear",
                            toolTip: "Clear the log (⌘K)",
                            action: #selector(clearActivityLog(_:)))
        default:
            return nil
        }
    }

    /// Clear — the toolbar item's action, and ⌘K's: the hidden main menu's
    /// "Clear Activity" item sends this to the responder chain with no
    /// target, and the chain reaches a window's DELEGATE, so it lands here
    /// exactly when the Activity window is key (elsewhere no responder
    /// answers, the menu item auto-disables, the keystroke is swallowed).
    @objc private func clearActivityLog(_ sender: Any?) {
        // AppKit dispatches actions on the main thread; the feed is main-actor.
        MainActor.assumeIsolated { feed.clear() }
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
        item.autovalidates = false   // nothing here depends on responder state
        return item
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
