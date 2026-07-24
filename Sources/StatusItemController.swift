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

    /// A pending update on one channel, as the menu shows it. `enabled` is
    /// false while the other channel is mid-install (installs are serialized
    /// app-wide — matches the Settings cards' disabled Update button).
    struct PendingUpdate: Equatable {
        let version: String
        let isMajor: Bool
        let enabled: Bool
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let foldersMenu = NSMenu()
    private let onOpenSettings: () -> Void
    private let onAbout: () -> Void

    /// Called just before the menu opens, so the owner can refresh live data
    /// (the folder list, device pause state) before it's shown.
    var onMenuWillOpen: (() -> Void)?

    /// Daemon operations, wired by the owner. The controller only reflects
    /// state and forwards intent.
    var onStartSyncthing: (() -> Void)?
    var onRescanAll: (() -> Void)?
    /// `true` = pause all devices, `false` = resume all.
    var onPauseToggle: ((_ pause: Bool) -> Void)?
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
    private var rescanItem: NSMenuItem?
    private var pauseToggleItem: NSMenuItem?
    private var allDevicesPaused = false
    private var activity: SyncActivity = .idle
    /// A folder Syncthing can't access (permission error) — needs the user.
    private var folderAttention = false
    private var appUpdate: PendingUpdate?
    private var syncthingUpdate: PendingUpdate?
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
    ///
    /// The daemon verbs (Web UI, Folders, Rescan, Pause) are HIDDEN — not
    /// dimmed — when the daemon isn't running: a column of disabled commands
    /// is noise. In their place the stopped/failed states show a single
    /// recovery action, Start Syncthing.
    func update(daemonState: SyncthingProcess.State) {
        self.daemonState = daemonState
        refreshSettingsBadge()
        switch daemonState {
        case .stopped:
            setStatus(dot: .tertiaryLabelColor, detail: "Not running")
            webUIURL = nil
            setDaemonVerbs(visible: false, canStart: true)
        case .starting:
            setStatus(dot: .systemOrange, detail: "Starting…")
            webUIURL = nil
            setDaemonVerbs(visible: false, canStart: false)
        case let .running(guiURL):
            setRunningStatus()
            webUIURL = guiURL
            setDaemonVerbs(visible: true, canStart: false)
        case let .failed(message):
            // The full (possibly long) message lives in the icon tooltip; the
            // menu line stays a one-glance summary.
            setStatus(dot: .systemRed, detail: Self.truncate(message, to: 60))
            webUIURL = nil
            setDaemonVerbs(visible: false, canStart: true)
        }
        refreshIcon()
    }

    /// The session's verified endpoint URL. Fresher than the launch-time URL in
    /// `update(daemonState:)` when the GUI address drifted mid-run (concrete-config
    /// case); the session publish always follows the daemon-state push, so this
    /// value wins while running.
    func update(webUIURL: String?) {
        self.webUIURL = webUIURL
    }

    private func setDaemonVerbs(visible: Bool, canStart: Bool) {
        for item in [webUIItem, foldersItem, rescanItem, pauseToggleItem] {
            item?.isHidden = !visible
        }
        startItem?.isHidden = !canStart
    }

    /// Reflect the monitor's live activity snapshot: the Pause⇄Resume toggle
    /// label, the status line, and the icon (Paused/Syncing marks). Fed by
    /// `SyncthingMonitor` over the daemon's push event stream, so it stays
    /// current without the menu being opened.
    func update(allDevicesPaused: Bool, activity: SyncActivity, folderAttention: Bool) {
        self.allDevicesPaused = allDevicesPaused
        self.activity = activity
        self.folderAttention = folderAttention
        pauseToggleItem?.title = allDevicesPaused ? "Resume All Devices" : "Pause All Devices"
        refreshSettingsBadge()
        if case .running = daemonState { setRunningStatus() }
        refreshIcon()
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
        let running = if case .running = daemonState { true } else { false }
        if running && folderAttention {
            if settingsItem?.image !== Self.attentionBadge {
                defaultSettingsImage = settingsItem?.image
                settingsItem?.image = Self.attentionBadge
            }
        } else if settingsItem?.image === Self.attentionBadge {
            settingsItem?.image = defaultSettingsImage
        }
    }

    /// The Settings… item's image before we overlaid the caution badge —
    /// the system-provided gear on macOS 26+, nil on older systems.
    private var defaultSettingsImage: NSImage?

    /// The same caution mark the Settings FDA section shows (orange
    /// exclamationmark.triangle.fill), rasterized into a REAL bitmap: the
    /// menu renderer doesn't draw color-configured symbol images (verified on
    /// macOS 27), and a handler-backed NSImage (deferred drawing) gets its
    /// icon column reserved a frame before its pixels exist — a visible
    /// "inset but empty" beat. A bitmap-backed image draws atomically.
    private static let attentionBadge: NSImage = {
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: nil)?
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
        NSColor.systemOrange.setFill()
        rect.fill(using: .sourceAtop)   // tint the glyph, keep its alpha
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.accessibilityDescription = "Needs attention"
        return image
    }()

    /// The running daemon's status line. Attention (a folder Syncthing can't
    /// access) outranks everything — it needs the user's action; Paused outranks
    /// activity: a pause is the user's deliberate mode, and dominates transient
    /// scan activity. The text distinguishes Scanning from Syncing (the icon
    /// stays coarse — one activity mark for either).
    private func setRunningStatus() {
        if folderAttention {
            setStatus(dot: .systemOrange, detail: "Can't access some folders")
        } else if allDevicesPaused {
            setStatus(dot: .systemOrange, detail: "Paused")
        } else {
            switch activity {
            case .syncing: setStatus(dot: .systemGreen, detail: "Syncing…")
            case .scanning: setStatus(dot: .systemGreen, detail: "Scanning…")
            case .idle: setStatus(dot: .systemGreen, detail: "Running")
            }
        }
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

    /// Choose the menu-bar icon from (daemon state, activity, update availability).
    ///
    /// State priority while running: Paused > Syncing > Idle — a pause is the
    /// user's deliberate mode and dominates transient activity. Failure shows
    /// the error mark; stopped/starting show the system-dimmed
    /// (`appearsDisabled`) idle mark — the native grammar for
    /// present-but-inactive, and it composes with the update arrow.
    private func refreshIcon() {
        let base: String
        let dimmed: Bool
        switch daemonState {
        case .running:
            // Attention = the error mark even though the daemon runs: the
            // condition needs the user, and the icon is the only always-visible
            // surface. Below that, Paused (deliberate mode) outranks Syncing.
            // Scanning and syncing share the one activity mark: the icon is a
            // preattentive summary ("busy"), the texts carry the distinction.
            base = folderAttention ? "Error"
                 : (allDevicesPaused ? "Paused" : (activity != .idle ? "Syncing" : "Idle"))
            dimmed = false
        case .stopped, .starting: base = "Idle"; dimmed = true
        case .failed: base = "Error"; dimmed = false
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
        let state: String
        switch daemonState {
        case .stopped: state = "Syncthing is not running"
        case .starting: state = "Syncthing is starting"
        case .running:
            state = folderAttention
                ? "Syncthing can't access some folders — open Settings (Full Disk Access may be needed)"
                : allDevicesPaused ? "Syncthing is paused"
                : activity == .syncing ? "Syncthing is syncing"
                : activity == .scanning ? "Syncthing is scanning"
                : "Syncthing is running"
        case let .failed(message): state = "Syncthing failed — \(message)"
        }
        var parts = ["Syncthing Menu — \(state)"]
        if let update = syncthingUpdate { parts.append("Syncthing \(update.version) available") }
        if let update = appUpdate { parts.append("Syncthing Menu \(update.version) available") }
        return parts.joined(separator: " · ")
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

        let folders = menu.addItem(withTitle: "Folders", action: nil, keyEquivalent: "")
        folders.submenu = foldersMenu
        foldersItem = folders
        update(folders: [])        // initial "No Folders" state

        let rescan = menu.addItem(withTitle: "Rescan All",
                                  action: #selector(rescanAll), keyEquivalent: "")
        rescan.target = self
        rescanItem = rescan

        let pauseToggle = menu.addItem(withTitle: "Pause All Devices",
                                       action: #selector(togglePauseAll), keyEquivalent: "")
        pauseToggle.target = self
        pauseToggleItem = pauseToggle

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
        onPauseToggle?(!allDevicesPaused)
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
