import AppKit
import Combine

/// Owns the menu-bar status item and its dropdown menu, and reflects the live
/// daemon state + update availability through the status-item icon and the menu.
/// Daemon state arrives by observing `SyncthingStatusModel` (the canonical
/// presentation model — the priority chain is resolved there); everything here
/// is a 1:1 rendering of its `display` value into this surface's media (status
/// row, icon, tooltip, verb visibility).
///
/// The menu groups this app's items (About, Settings) above the Syncthing items
/// (status, web UI, folders, devices) — matching the Settings and About windows.
///
/// The Folders and Devices lists render from the monitor's `Snapshot` — the
/// same one the status model is fed from — pushed live by the owner. Nothing
/// is fetched on menu open: rows, list marks, and the bulk verbs' state all
/// come from one value, so they can't disagree, and they update in place
/// while the menu is showing (the snapshot changes by daemon event).
final class StatusItemController: NSObject {
    typealias Snapshot = SyncthingMonitor.Snapshot

    /// A pending update on one channel, as the menu shows it. `enabled` is
    /// false while the other channel is mid-install (installs are serialized
    /// app-wide — matches the Settings cards' disabled Update button).
    struct PendingUpdate: Equatable {
        let version: String
        let isMajor: Bool
        let enabled: Bool
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // The menus are internal (not private) so tests can read what rendered.
    let menu = NSMenu()
    let foldersMenu = NSMenu()
    let devicesMenu = NSMenu()
    private let status: SyncthingStatusModel
    private var statusSink: AnyCancellable?
    private let onOpenSettings: () -> Void
    private let onAbout: () -> Void

    /// Daemon operations, wired by the owner. The controller only reflects
    /// state and forwards intent; every verb's result comes back through the
    /// snapshot, nothing is flipped locally.
    var onStartSyncthing: (() -> Void)?
    var onRescanAll: (() -> Void)?
    /// `true` = pause all devices, `false` = resume all.
    var onPauseToggle: ((_ pause: Bool) -> Void)?
    /// Per-folder verbs from a folder's submenu.
    var onRescanFolder: ((_ id: String) -> Void)?
    var onSetFolderPaused: ((_ id: String, _ paused: Bool) -> Void)?
    /// The per-device verb from a device's submenu.
    var onSetDevicePaused: ((_ id: String, _ paused: Bool) -> Void)?
    /// Apply the pending update (the click is the consent — majors included).
    var onUpdateApp: (() -> Void)?
    var onUpdateSyncthing: (() -> Void)?
    /// `reset` = the Option-key alternate: open at default frame with
    /// default column widths (a factory reset of the window's layout).
    var onOpenActivity: ((_ reset: Bool) -> Void)?

    private var statusMenuItem: NSMenuItem?
    private let statusRow = StatusRowView()
    private var appUpdateItem: NSMenuItem?
    private var syncthingUpdateItem: NSMenuItem?
    private var startItem: NSMenuItem?
    private var settingsItem: NSMenuItem?
    private var webUIItem: NSMenuItem?
    private var activityItem: NSMenuItem?
    private var foldersItem: NSMenuItem?
    private var devicesItem: NSMenuItem?
    private var rescanItem: NSMenuItem?
    private var pauseToggleItem: NSMenuItem?
    private var appUpdate: PendingUpdate?
    private var syncthingUpdate: PendingUpdate?
    /// The managed daemon's GUI URL when running; nil otherwise.
    private var webUIURL: String?

    private var updateAvailable = false
    /// The last snapshot rendered. `update(snapshot:)` re-renders a list
    /// only when THAT list changed (activity flips every few seconds on a
    /// busy daemon and the lists never render it).
    private var snapshot = Snapshot()
    /// The rows currently in each list (or its placeholder) — removed
    /// exactly on re-render, so the header above them is never counted.
    private var folderRows: [NSMenuItem] = []
    private var deviceRows: [NSMenuItem] = []

    init(status: SyncthingStatusModel,
         onOpenSettings: @escaping () -> Void, onAbout: @escaping () -> Void) {
        self.status = status
        self.onOpenSettings = onOpenSettings
        self.onAbout = onAbout
        super.init()
        buildMenu()
        render()
        statusItem.menu = menu
        // objectWillChange (not $phase): a smoothing drop changes `display`
        // without a phase change. receive-on-main defers one tick so the
        // model's new values are settled when we read them (it emits on
        // willSet).
        statusSink = status.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyStatus() }
        applyStatus()
    }

    // MARK: - Live state

    /// Render the model's current state into this surface: status row, verb
    /// visibility, Settings badge, and icon. Runs on every phase change (and
    /// once at init), whether the change came from the process push or the
    /// monitor's event stream — so the menu stays current without being
    /// opened. The lists render separately, from the snapshot
    /// (`update(snapshot:)`).
    ///
    /// The daemon verbs (Web UI, Folders, Devices) are HIDDEN — not
    /// dimmed — when the daemon isn't running: a column of disabled commands
    /// is noise. In their place the stopped/failed states show a single
    /// recovery action, Start Syncthing.
    private func applyStatus() {
        // The full (possibly long) failure message lives in the icon tooltip;
        // the menu line stays a one-glance summary.
        setStatus(dot: Self.dotColor(for: status.display),
                  detail: Self.truncate(status.statusText, to: 60))
        if status.display == .updating {
            // Mid-update the phase churns through running/stopped/starting; a
            // flickering verb list — or a Start Syncthing offer while our own
            // re-root is mid-flight — would be noise. One quiet line.
            setDaemonVerbs(visible: false, canStart: false)
        } else {
            switch status.phase {
            case .running: setDaemonVerbs(visible: true, canStart: false)
            case .starting: setDaemonVerbs(visible: false, canStart: false)
            case .notRunning, .failed: setDaemonVerbs(visible: false, canStart: true)
            // Self-managed and not connected: no daemon verbs, and no Start either —
            // starting that daemon is the user's job, not ours.
            case .selfManaged: setDaemonVerbs(visible: false, canStart: false)
            }
        }
        refreshSettingsBadge()
        refreshIcon()
    }

    /// The status row's preattentive cue, 1:1 on the display state: green
    /// running / orange transitional-or-needs-user / red failed / neutral
    /// stopped. Color is never the sole carrier — the detail text states the
    /// same fact in words.
    /// The dot reports HEALTH; the text beside it reports state. Green =
    /// healthy, orange = degraded or in transition, red = failed, grey = off.
    /// All Paused is a healthy state the user chose (the daemon is up and
    /// still scanning locally), so it's green: the word, the ‖ icon, and the
    /// marks already say "not syncing" — orange would recode a choice as a
    /// warning, and grey would misfile it with "Not running".
    private static func dotColor(for display: SyncthingStatusModel.DisplayState) -> NSColor {
        switch display {
        case .notRunning, .notConfigured: .tertiaryLabelColor
        case .starting, .updating, .connecting, .unreachable: .systemOrange
        case .failed, .keyRejected: .systemRed
        case .attention: .systemOrange
        case .paused, .syncing, .scanning, .running: .systemGreen
        }
    }

    /// The session's verified endpoint URL while the daemon runs; nil when it
    /// stops. Pushed by the owner (the session layer verifies fresher URLs than
    /// the launch-time one when the GUI address drifts mid-run).
    func update(webUIURL: String?) {
        self.webUIURL = webUIURL
    }

    private func setDaemonVerbs(visible: Bool, canStart: Bool) {
        for item in [webUIItem, foldersItem, devicesItem] {
            item?.isHidden = !visible
        }
        startItem?.isHidden = !canStart
    }

    /// A caution badge on Settings… while a folder is blocked on permissions:
    /// the status line names the problem, the badge points at where the fix
    /// lives (the FDA section there is in its alert state). Settings is an
    /// app-section item, so the daemon section stays free of app verbs.
    ///
    /// macOS 26+ AUTO-ASSIGNS the system gear to a "Settings…" item by
    /// setting its `image` (lazily — not yet present at build time). So never
    /// write `nil` as the rest state: only swap in the badge (capturing
    /// whatever the system put there) and restore the captured image when the
    /// attention clears. Writing nil permanently killed the system gear.
    private func refreshSettingsBadge() {
        if status.needsAttention {
            if settingsItem?.image !== Self.attentionBadge {
                defaultSettingsImage = settingsItem?.image
                settingsItem?.image = Self.attentionBadge
            }
        } else if settingsItem?.image === Self.attentionBadge {
            settingsItem?.image = defaultSettingsImage
        }
    }

    /// The owner pushes every monitor snapshot (and the empty one at
    /// teardown). Only a list that changed is re-rendered; an unchanged one
    /// is untouched AppKit.
    func update(snapshot: Snapshot) {
        let previous = self.snapshot
        self.snapshot = snapshot
        if snapshot.folders != previous.folders { renderFolders() }
        if snapshot.devices != previous.devices { renderDevices() }
    }

    /// Initial render, from the empty snapshot: placeholders + dimmed bulk verbs.
    private func render() {
        renderFolders()
        renderDevices()
    }

    /// The mark for one object — or for a list, as the mark of its rows —
    /// ONE rule everywhere: the caution mark while blocked on permissions
    /// (the state that needs the user) outranks the pause mark; a healthy
    /// running object gets none — ink only where it carries information.
    /// Paused and attention are the only marked states, deliberately: both
    /// are stable and actionable; scanning/syncing belong to the icon.
    private static func mark(attention: Bool = false, paused: Bool) -> NSImage? {
        attention ? attentionBadge : paused ? pausedBadge : nil
    }

    /// The Settings… item's image before we overlaid the caution badge —
    /// the system-provided gear on macOS 26+, nil on older systems.
    private var defaultSettingsImage: NSImage?

    /// The same caution mark the Settings FDA section shows (orange
    /// exclamationmark.triangle.fill). Also marks a folder row that is
    /// blocked on permissions.
    private static let attentionBadge: NSImage = rasterize(
        symbol: "exclamationmark.triangle.fill", tint: .systemOrange,
        accessibilityDescription: "Needs attention")

    /// The paused mark on a folder row. A TEMPLATE image: the menu draws its
    /// alpha in the label color, so it follows dark mode and inverts on the
    /// highlighted row like the title does.
    private static let pausedBadge: NSImage = rasterize(
        symbol: "pause.fill", tint: nil, accessibilityDescription: "Paused")

    /// A symbol rasterized into a REAL bitmap: the menu renderer doesn't draw
    /// color-configured symbol images (verified on macOS 27), and a
    /// handler-backed NSImage (deferred drawing) gets its icon column
    /// reserved a frame before its pixels exist — a visible "inset but empty"
    /// beat. A bitmap-backed image draws atomically. `tint: nil` yields a
    /// template image (the alpha mask alone is used, so the fill color is
    /// immaterial).
    private static func rasterize(symbol name: String, tint: NSColor?,
                                  accessibilityDescription: String) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else {
            return NSImage()
        }
        let size = symbol.size
        let scale: CGFloat = 2   // Retina rasterization
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage()
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        symbol.draw(in: rect)
        (tint ?? .black).setFill()
        rect.fill(using: .sourceAtop)   // tint the glyph, keep its alpha
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = tint == nil
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Both lists share one shape — the list's daemon-backed bulk verb leads
    /// (built once in `buildMenu`; the shape of Apple's Wi-Fi and Bluetooth
    /// menus: the global verb is the nearest target as the submenu opens),
    /// then a separator, then the rows: object, then verb.
    ///
    /// Folders: Rescan All (the folder-less scan; dimmed with no folders),
    /// then a row per folder — mark + name — opening its verbs. Empty → a
    /// single, non-selectable "No Folders".
    private func renderFolders() {
        let folders = snapshot.folders
        rescanItem?.isEnabled = !folders.isEmpty
        folderRows = reconcile(rows: folderRows, in: foldersMenu, with: folders,
                               id: \.id, placeholder: "No Folders", configure: configureFolderRow)
        foldersItem?.image = Self.mark(attention: snapshot.folderAttention,
                                       paused: snapshot.anyFolderPaused)
    }

    /// Devices: Pause All ⇄ Resume All (the daemon's all-devices pause; the
    /// title follows `allDevicesPaused` — scoped by its list the title drops
    /// the noun, as Edit's "Select All" does; opposites swap, a checkmark is
    /// for toggles; dimmed with no devices), then a row per remote device —
    /// mark + name — opening its verbs. Empty → "No Devices".
    private func renderDevices() {
        let devices = snapshot.devices
        pauseToggleItem?.title = snapshot.allDevicesPaused ? "Resume All" : "Pause All"
        pauseToggleItem?.isEnabled = !devices.isEmpty
        deviceRows = reconcile(rows: deviceRows, in: devicesMenu, with: devices,
                               id: \.id, placeholder: "No Devices", configure: configureDeviceRow)
        devicesItem?.image = Self.mark(paused: snapshot.anyDevicePaused)
    }

    /// Bring a list's rows to `objects`. When the id sequence is unchanged
    /// (the common case: a pause flip, a rename) every row is updated IN
    /// PLACE — title, mark, verbs — so a submenu open under the pointer
    /// survives the update; only an added/removed/reordered object replaces
    /// the rows. Rows carry their object's id as `representedObject`; the
    /// placeholder carries none, so it always gets replaced.
    private func reconcile<T>(rows: [NSMenuItem], in menu: NSMenu, with objects: [T],
                              id: (T) -> String, placeholder: String,
                              configure: (NSMenuItem, T) -> Void) -> [NSMenuItem] {
        if !objects.isEmpty, rows.map({ $0.representedObject as? String }) == objects.map(id) {
            for (row, object) in zip(rows, objects) { configure(row, object) }
            return rows
        }
        for row in rows { menu.removeItem(row) }
        guard !objects.isEmpty else {
            let none = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return [none]
        }
        return objects.map { object in
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.representedObject = id(object)
            configure(row, object)
            menu.addItem(row)
            return row
        }
    }

    /// One folder row: mark + name, and its verbs — Open in Finder · Rescan ·
    /// — · Pause ⇄ Resume. Open in Finder leads: the most frequent verb at
    /// the default position. Rescan is dimmed (not hidden — the submenu keeps
    /// one shape) while the folder is paused: a paused folder isn't running,
    /// so it can't scan (the daemon errors). Pause/Resume is a swapping
    /// title, matching Pause All ⇄ Resume All one level up. Every verb
    /// carries the whole folder as its represented object, so a mis-wired
    /// selector fails its cast instead of, say, opening Finder on an id.
    private func configureFolderRow(_ row: NSMenuItem, _ folder: Snapshot.Folder) {
        row.title = folder.name
        row.image = Self.mark(attention: folder.attention, paused: folder.paused)
        let verbs = row.submenu ?? Self.verbMenu(
            verb("Open in Finder", #selector(openFolder(_:))),
            verb("Rescan", #selector(rescanFolder(_:))),
            .separator(),
            verb("Pause", #selector(toggleFolderPaused(_:))))
        row.submenu = verbs
        for item in verbs.items where !item.isSeparatorItem { item.representedObject = folder }
        verbs.item(for: #selector(rescanFolder(_:)))?.isEnabled = !folder.paused
        verbs.item(for: #selector(toggleFolderPaused(_:)))?.title = folder.paused ? "Resume" : "Pause"
    }

    /// One device row: mark + name, and its one verb — Pause ⇄ Resume, the
    /// only per-device verb the daemon has. A submenu (not a direct toggle
    /// on the row) keeps the two lists in one grammar.
    private func configureDeviceRow(_ row: NSMenuItem, _ device: Snapshot.Device) {
        row.title = device.name
        row.image = Self.mark(paused: device.paused)
        let verbs = row.submenu ?? Self.verbMenu(verb("Pause", #selector(toggleDevicePaused(_:))))
        row.submenu = verbs
        let pause = verbs.item(for: #selector(toggleDevicePaused(_:)))
        pause?.representedObject = device
        pause?.title = device.paused ? "Resume" : "Pause"
    }

    private func verb(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// A verb submenu: enablement is ours (a dimmed Rescan must stay dimmed).
    private static func verbMenu(_ items: NSMenuItem...) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        return menu
    }

    /// Reflect pending updates: a direct action item per channel ("Update
    /// Syncthing to v2.1.1"), shown only while that update is available, plus
    /// the icon's update arrow (one arrow means "something is updatable"; the
    /// dropdown and tooltip disambiguate and name versions).
    func update(appUpdate: PendingUpdate?, syncthingUpdate: PendingUpdate?) {
        self.appUpdate = appUpdate
        self.syncthingUpdate = syncthingUpdate

        configure(appUpdateItem, for: appUpdate,
                  title: appUpdate.map { "Update Syncthing Menu to \($0.version)" })
        configure(syncthingUpdateItem, for: syncthingUpdate,
                  title: syncthingUpdate.map {
                      "Update Syncthing to \($0.version)\($0.isMajor ? " · major update" : "")"
                  })

        updateAvailable = appUpdate != nil || syncthingUpdate != nil
        refreshIcon()   // arrow variant and tooltip (which names versions)
    }

    private func configure(_ item: NSMenuItem?, for update: PendingUpdate?, title: String?) {
        item?.isHidden = update == nil
        item?.title = title ?? ""
        item?.isEnabled = update?.enabled ?? false
    }

    /// The status line is informational and non-interactive — a view-backed
    /// menu item (see `StatusRowView`). The dot is a preattentive state cue
    /// (green running / orange starting / red failed / neutral stopped) —
    /// color is never the sole carrier, the detail text always states the
    /// same fact in words.
    private func setStatus(dot: NSColor, detail: String) {
        statusRow.set(dotColor: dot, detail: detail)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Choose the menu-bar icon, 1:1 on the display state (+ update
    /// availability). Attention shows the error mark even though the daemon
    /// runs: the condition needs the user, and the icon is the only
    /// always-visible surface. Scanning and syncing share the one activity
    /// mark: the icon is a preattentive summary ("busy"), the texts carry the
    /// distinction. Stopped/starting show the system-dimmed
    /// (`appearsDisabled`) idle mark — the native grammar for
    /// present-but-inactive, and it composes with the update arrow.
    private func refreshIcon() {
        let base: String
        var dimmed = false
        switch status.display {
        case .failed, .attention, .keyRejected: base = "Error"
        case .paused: base = "Paused"
        case .syncing, .scanning: base = "Syncing"
        case .running: base = "Idle"
        case .notRunning, .starting, .updating, .notConfigured, .connecting, .unreachable:
            base = "Idle"; dimmed = true
        }
        let name = "Status\(base)\(updateAvailable ? "Update" : "")"
        let image = NSImage(named: name)
        image?.isTemplate = true
        let summary = statusSummary()
        image?.accessibilityDescription = summary
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = dimmed
        statusItem.button?.toolTip = summary
    }

    /// One-line state summary for the icon's tooltip and accessibility
    /// description — the zero-click reading of the icon. Pending updates are
    /// named with their versions.
    private func statusSummary() -> String {
        var parts = ["Syncthing Menu — \(status.summaryText)"]
        if let update = syncthingUpdate { parts.append("Syncthing \(update.version) available") }
        if let update = appUpdate { parts.append("Syncthing Menu \(update.version) available") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Menu

    private func buildMenu() {
        // We manage item enablement ourselves.
        menu.autoenablesItems = false
        foldersMenu.autoenablesItems = false
        devicesMenu.autoenablesItems = false

        // ── Syncthing Menu (this app) ─────────────────────────────────────────
        let aboutItem = menu.addItem(withTitle: "About Syncthing Menu",
                                     action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(.separator())

        let activity = menu.addItem(withTitle: "Activity…",
                                    action: #selector(openActivity), keyEquivalent: "")
        activity.target = self
        activityItem = activity

        // Holding ⌥ swaps the item for its reset variant — the native
        // alternate-item idiom, so the escape hatch is discoverable.
        let activityReset = menu.addItem(withTitle: "Activity (Reset Layout)…",
                                         action: #selector(openActivityReset),
                                         keyEquivalent: "")
        activityReset.target = self
        activityReset.isAlternate = true
        activityReset.keyEquivalentModifierMask = [.option]

        let settings = menu.addItem(withTitle: "Settings…",
                                    action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        settingsItem = settings

        // Direct update action, shown only while an app update is pending.
        let appUpdate = menu.addItem(withTitle: "", action: #selector(updateApp),
                                     keyEquivalent: "")
        appUpdate.target = self
        appUpdate.isHidden = true
        appUpdateItem = appUpdate

        menu.addItem(.separator())

        // ── Syncthing (the daemon) ────────────────────────────────────────────
        // The item title is a fallback only (accessibility reads the view's
        // label); the row renders via the custom view. Enabled so the renderer
        // doesn't fade the view — the view itself is inert (no action, clicks
        // swallowed), so the item still can't highlight or fire.
        let status = menu.addItem(withTitle: "Syncthing status",
                                  action: nil, keyEquivalent: "")
        status.view = statusRow
        statusMenuItem = status
        setStatus(dot: .tertiaryLabelColor, detail: "Not running")

        // Recovery action for the stopped/failed states; hidden while the
        // daemon is starting or running.
        let start = menu.addItem(withTitle: "Start Syncthing",
                                 action: #selector(startSyncthing), keyEquivalent: "")
        start.target = self
        startItem = start

        // Direct update action, shown only while a Syncthing update is pending
        // (the channel resets on daemon disconnect, so this hides itself when
        // the daemon is down).
        let syncthingUpdate = menu.addItem(withTitle: "", action: #selector(updateSyncthing),
                                           keyEquivalent: "")
        syncthingUpdate.target = self
        syncthingUpdate.isHidden = true
        syncthingUpdateItem = syncthingUpdate

        let webUI = menu.addItem(withTitle: "Open Syncthing",
                                 action: #selector(openWebUI), keyEquivalent: "")
        webUI.target = self
        webUIItem = webUI

        // The two lists: each leads with its one daemon-backed bulk verb (a
        // stable item), then a separator; the rows below are rendered from
        // the snapshot (`render`).
        let folders = menu.addItem(withTitle: "Folders", action: nil, keyEquivalent: "")
        folders.submenu = foldersMenu
        foldersItem = folders
        let rescan = foldersMenu.addItem(withTitle: "Rescan All",
                                         action: #selector(rescanAll), keyEquivalent: "")
        rescan.target = self
        rescanItem = rescan
        foldersMenu.addItem(.separator())

        let devices = menu.addItem(withTitle: "Devices", action: nil, keyEquivalent: "")
        devices.submenu = devicesMenu
        devicesItem = devices
        let pauseToggle = devicesMenu.addItem(withTitle: "", action: #selector(togglePauseAll),
                                              keyEquivalent: "")
        pauseToggle.target = self
        pauseToggleItem = pauseToggle
        devicesMenu.addItem(.separator())

        // Initial state: daemon not running → verbs hidden, Start showing.
        setDaemonVerbs(visible: false, canStart: true)

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

    @objc private func startSyncthing() {
        onStartSyncthing?()
    }

    @objc private func openActivity() {
        onOpenActivity?(false)
    }

    @objc private func openActivityReset() {
        onOpenActivity?(true)
    }

    @objc private func updateApp() {
        onUpdateApp?()
    }

    @objc private func updateSyncthing() {
        onUpdateSyncthing?()
    }

    @objc private func rescanAll() {
        onRescanAll?()
    }

    @objc private func togglePauseAll() {
        onPauseToggle?(!snapshot.allDevicesPaused)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Snapshot.Folder else { return }
        let expanded = (folder.path as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }

    @objc private func rescanFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Snapshot.Folder else { return }
        onRescanFolder?(folder.id)
    }

    @objc private func toggleFolderPaused(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Snapshot.Folder else { return }
        onSetFolderPaused?(folder.id, !folder.paused)
    }

    @objc private func toggleDevicePaused(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Snapshot.Device else { return }
        onSetDevicePaused?(device.id, !device.paused)
    }

    @objc private func quit() {
        // The daemon is stopped via applicationWillTerminate before exit.
        NSApplication.shared.terminate(nil)
    }
}


/// Full-contrast, non-interactive status row for the dropdown.
///
/// A disabled NSMenuItem's title is always drawn dimmed — and as of modern
/// macOS the renderer fades an `attributedTitle`'s explicit colors too
/// (verified on macOS 27), so a stock item can't be both readable and
/// non-selectable. A view-backed item is the remaining path: AppKit doesn't
/// restyle a custom view, and a view with no action neither highlights on
/// hover nor fires on click.
private final class StatusRowView: NSView {
    private let dot = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// Leading/trailing inset matching where standard menu-item text starts.
    /// Tuned by eye against sibling items; revisit if a macOS release shifts
    /// menu metrics.
    private static let textInset: CGFloat = 14
    private static let dotTextGap: CGFloat = 5

    init() {
        super.init(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Self.dotTextGap),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(dotColor: NSColor, detail: String) {
        dot.contentTintColor = dotColor
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(
            string: "Syncthing",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: ": \(detail)",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = text
        // NSMenu sizes view-backed items from their frame.
        frame.size = fittingSize
    }

    // The row is informational — swallow clicks so it can never act.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

private extension NSMenu {
    /// The item wired to `action` — how a row's verbs are found for an
    /// in-place update (never by index).
    func item(for action: Selector) -> NSMenuItem? {
        items.first { $0.action == action }
    }
}
