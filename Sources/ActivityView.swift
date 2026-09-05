import AppKit
import SwiftUI

/// The Activity window's content: the live activity feed, nothing else —
/// identity, global state, and the window's verbs live in the unified title
/// bar (`ActivityWindowController`), so the content area is pure data.
///
/// Column design (see the log model in `ActivityFeed`): each entry is an
/// immutable logical event — the Event column (verb + glyph: what happened),
/// then Name, Folder, Device, Time. A deletion marks itself on the Name
/// (strikethrough — see `NameCell`; the dedicated operation column was
/// removed 2026-08-18 as near-constant noise). Full status words live in
/// the Event column itself; color reinforces, never alone. New rows
/// appearing is the ONLY motion — entries never mutate, so nothing in the
/// table ever jumps or re-sorts on its own. (Verb wording and glyph choices
/// are provisional pending the visual-language pass.)
///
/// Trailing-space note (investigated at length 2026-07-22/23): blank
/// header-styled space after the Time column is mostly NATIVE chrome — the
/// vertical scrollbar's reserved lane (when the system resolves to
/// space-reserving scrollbars, e.g. a mouse is attached) plus the table
/// style's edge insets. It is not an actual column.
struct ActivityView: View {
    @ObservedObject var feed: ActivityFeed
    @ObservedObject var display: ActivityDisplayModel

    var body: some View {
        // ONE minute-clock for the whole view, passed down as a plain value:
        // per-cell TimelineViews (timers firing inside NSTableView cell
        // contexts) caused reentrant-delegate warnings when overnight timer
        // coalescing batched their wakeups (diagnosed 2026-07-24 from the
        // 10s-quantized warning timestamps). A single top-down state change
        // per minute keeps the cells timer-free.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let visible = feed.entries.filter(display.allows)
                .sorted(using: display.effectiveSortOrder)
            // Markers pass every filter, so under an active filter or search
            // "nothing matches" is judged on the sync facts alone — a lone
            // marker must not stand in for a result.
            let hasActivity = visible.contains { !$0.kind.isMarker }
            let hiddenActivity = feed.entries.contains { !$0.kind.isMarker } && !hasActivity
            VStack(spacing: 0) {
                // A filtered feed must LOOK filtered — a quiet list under an
                // invisible filter reads as "syncing broke".
                if display.isActive {
                    filterBar
                    Divider()
                }
                Group {
                    if visible.isEmpty || (display.isActive && !hasActivity) {
                        emptyFeed(filtered: display.isActive && hiddenActivity)
                    } else if #available(macOS 14.0, *) {
                        CustomizableFeedTable(entries: visible, sortOrder: sortBinding,
                                              now: context.date)
                    } else {
                        LegacyFeedTable(entries: visible, sortOrder: sortBinding,
                                        now: context.date)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 280)
    }

    /// The Table's sort binding, with one adjustment on the way in: a FRESH
    /// click on the Time column starts DESCENDING (newest first) — ascending
    /// Time (oldest first) is almost never what an activity log wants, and
    /// Finder treats its date columns the same way. Toggling Time once it's
    /// already the sort column behaves normally.
    private var sortBinding: Binding<[KeyPathComparator<ActivityFeed.Entry>]> {
        Binding {
            display.sortOrder
        } set: { new in
            if let first = new.first, first.keyPath == \ActivityFeed.Entry.time,
               first.order == .forward,
               display.sortOrder.first?.keyPath != \ActivityFeed.Entry.time {
                display.sortOrder = ActivityDisplayModel.defaultSortOrder
            } else {
                display.sortOrder = new
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(display.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                display.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear filters")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// An empty window must explain itself: what will appear, that nothing
    /// being here is normal — or that a filter is hiding what IS here. When
    /// a name search comes up empty while the log holds BULK entries, say
    /// so: the searched-for file may be inside a count (bulk entries carry
    /// no paths), and silence would read as "my file didn't sync".
    private func emptyFeed(filtered: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: filtered ? "line.3.horizontal.decrease" : "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(filtered ? "No matching activity" : "No activity yet")
                .foregroundStyle(.secondary)
            if filtered {
                Text("Filters are hiding the current activity.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !display.searchText.isEmpty,
                   feed.entries.contains(where: { $0.bulkCount != nil }) {
                    Text("Some changes were recorded in bulk and can't be matched by name.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("Clear Filters") { display.clear() }
                    .controlSize(.small)
            } else {
                Text("File changes Syncthing detects or applies will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Activity window's display state: the filter (two independent groups
/// over an entry's static facts — direction and operation; an entry shows
/// iff its direction AND its operation are enabled; event kind is a possible
/// third group later) and the sort order (Finder-style single sort column,
/// Name as tiebreaker). Display-only and deliberately transient: everything
/// here resets with the app — a persisted hidden filter is the "syncing
/// broke" trap in durable form.
final class ActivityDisplayModel: ObservableObject {
    /// Direction is a property of the verb: detections and the
    /// sending/delivered kinds are outbound — changes from this Mac; the
    /// item kinds are inbound — changes from other devices. The popover's
    /// "Changed On" labels stay truthful under that mapping.
    @Published var showOutbound = true
    @Published var showInbound = true
    @Published var showModified = true
    @Published var showDeleted = true

    /// The toolbar search field's text: case-insensitive substring match
    /// against the folder-relative path (a superset of "part of a
    /// filename"). Brute force over ≤500 retained entries — trivially cheap,
    /// and it doubles as the episode lens: searching a filename shows that
    /// file's lifecycle thread in order. Bulk entries carry no path, so they
    /// never match a non-empty search (documented boundary of the aggregate
    /// tier; the empty state says so). Transient like every filter here.
    @Published var searchText = ""

    /// The third group: folder & device event rows (pause/resume, peers
    /// online/offline, folder errors, long scans, watcher state). On by
    /// default; off lets someone watching a transfer hide the chatter.
    @Published var showDaemonEvents = true

    static let defaultSortOrder = [KeyPathComparator(\ActivityFeed.Entry.time, order: .reverse)]

    /// The user's chosen sort (default: newest first). The Table binding
    /// writes it; display sorting applies `effectiveSortOrder`.
    @Published var sortOrder = ActivityDisplayModel.defaultSortOrder

    /// The applied sort: the chosen column, then Name as tiebreaker (unless
    /// Name IS the chosen column).
    var effectiveSortOrder: [KeyPathComparator<ActivityFeed.Entry>] {
        var order = sortOrder
        if sortOrder.first?.keyPath != \ActivityFeed.Entry.path {
            order.append(KeyPathComparator(\ActivityFeed.Entry.path,
                                           comparator: String.StandardComparator.localizedStandard))
        }
        return order
    }

    var isActive: Bool {
        !(showOutbound && showInbound && showModified && showDeleted
            && showDaemonEvents && searchText.isEmpty)
    }

    /// Markers always pass: they explain the gaps in whatever the filter or
    /// search leaves visible (a searched file's thread includes the pauses
    /// that interrupted it).
    /// A name search shows file rows only: markers and daemon events have
    /// no path, and a search follows one file's thread (decided 2026-09-04
    /// — markers had passed through, and every search came back topped
    /// with "Recording started" and "Syncthing connected"). Outside a
    /// search, markers bypass the checkbox groups and daemon events follow
    /// their own switch.
    func allows(_ entry: ActivityFeed.Entry) -> Bool {
        if entry.kind.isMarker { return searchText.isEmpty }
        if entry.kind.isDaemonEvent { return showDaemonEvents && searchText.isEmpty }
        return (entry.kind.isOutbound ? showOutbound : showInbound)
            && (entry.operation == .deleted ? showDeleted : showModified)
            && (searchText.isEmpty
                || entry.path.localizedCaseInsensitiveContains(searchText))
    }

    /// Clear the FILTERS only (the filter bar's ✕ / Clear Filters buttons).
    /// The search text is part of the view's scoping, so it clears too.
    func clear() {
        showOutbound = true
        showInbound = true
        showModified = true
        showDeleted = true
        showDaemonEvents = true
        searchText = ""
    }

    /// Factory reset (the menu's ⌥ alternate): filters AND sort.
    func resetDisplay() {
        clear()
        sortOrder = Self.defaultSortOrder
    }

    /// The filter bar's full reading. Grammar: "Showing <what> [from
    /// <where>] [matching “<text>”]" — <what> is the selected change type,
    /// or "changes" when both types are on and only location or search
    /// constrains; an impossible selection (either checkbox group fully
    /// unchecked) reads "Showing no changes".
    var summary: String {
        if (!showModified && !showDeleted) || (!showOutbound && !showInbound) {
            return "Showing no changes"
        }
        var text = "Showing "
        if showModified != showDeleted {
            text += showModified ? "adds & modifies" : "deletes"
        } else {
            text += "changes"
        }
        if showOutbound != showInbound {
            text += showOutbound ? " from this Mac" : " from other devices"
        }
        if !searchText.isEmpty {
            text += " matching “\(searchText)”"
        }
        if !showDaemonEvents {
            text += " (folder & device events hidden)"
        }
        return text
    }
}

/// The Filter toolbar button's popover: the two checkbox groups.
struct ActivityFilterPopoverView: View {
    @ObservedObject var display: ActivityDisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Change Type")
                .font(.subheadline.weight(.semibold))
            Toggle("Adds & Modifies", isOn: $display.showModified)
            Toggle("Deletes", isOn: $display.showDeleted)
            Divider()
                .padding(.vertical, 4)
            Text("Changed On")
                .font(.subheadline.weight(.semibold))
            Toggle("This Mac", isOn: $display.showOutbound)
            Toggle("Other Devices", isOn: $display.showInbound)
            Divider()
                .padding(.vertical, 4)
            Text("Also Show")
                .font(.subheadline.weight(.semibold))
            Toggle("Folder & Device Events", isOn: $display.showDaemonEvents)
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 190, alignment: .leading)
    }
}

/// The Activity window's persisted column-layout store and its factory-reset
/// hook (the menu's ⌥ "Activity (Reset Layout)…" alternate): the controller
/// clears the store and posts the notification; a live table resets its
/// customization state on receipt.
enum ActivityColumnStore {
    static let defaultsKey = "activity.columns"

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

extension Notification.Name {
    static let activityLayoutReset = Notification.Name("ActivityLayoutReset")
}

/// macOS 14+: column widths/order persist across launches via
/// `TableColumnCustomization` (resize is a persisted customization behavior).
/// The macOS 13 fallback below renders the same columns without persistence.
@available(macOS 14.0, *)
private struct CustomizableFeedTable: View {
    let entries: [ActivityFeed.Entry]
    @Binding var sortOrder: [KeyPathComparator<ActivityFeed.Entry>]
    let now: Date
    @State private var customization: TableColumnCustomization<ActivityFeed.Entry>

    init(entries: [ActivityFeed.Entry],
         sortOrder: Binding<[KeyPathComparator<ActivityFeed.Entry>]>,
         now: Date) {
        self.entries = entries
        self._sortOrder = sortOrder
        self.now = now
        if let data = UserDefaults.standard.data(forKey: ActivityColumnStore.defaultsKey),
           let saved = try? JSONDecoder().decode(
               TableColumnCustomization<ActivityFeed.Entry>.self, from: data) {
            _customization = State(initialValue: saved)
        } else {
            _customization = State(initialValue: .init())
        }
    }

    var body: some View {
        Table(entries, sortOrder: $sortOrder, columnCustomization: $customization) {
            TableColumn("Event", value: \.kindSortKey) { entry in
                EventCell(kind: entry.kind)
            }
            .width(min: 90, ideal: 120)
            .customizationID("event")
            TableColumn("Name", value: \.path,
                        comparator: String.StandardComparator.localizedStandard) { entry in
                NameCell(entry: entry)
            }
            .customizationID("name")
            TableColumn("Folder", value: \.folderLabel,
                        comparator: String.StandardComparator.localizedStandard) { entry in
                Text(entry.folderLabel).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
            .customizationID("folder")
            TableColumn("Device", value: \.partyDisplay,
                        comparator: String.StandardComparator.localizedStandard) { entry in
                PartyCell(entry: entry)
            }
            .width(min: 60, ideal: 90)
            .customizationID("device")
            TableColumn("Time", value: \.time) { entry in
                TimeCell(time: entry.time, now: now)
            }
            .width(min: 70, ideal: 90)
            .customizationID("time")
        }
        .onChange(of: customization) { _, new in
            if let data = try? JSONEncoder().encode(new) {
                UserDefaults.standard.set(data, forKey: ActivityColumnStore.defaultsKey)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activityLayoutReset)) { _ in
            customization = .init()
        }
    }
}

/// macOS 13: same columns, no width persistence (the customization API is 14+).
private struct LegacyFeedTable: View {
    let entries: [ActivityFeed.Entry]
    @Binding var sortOrder: [KeyPathComparator<ActivityFeed.Entry>]
    let now: Date

    var body: some View {
        Table(entries, sortOrder: $sortOrder) {
            TableColumn("Event", value: \.kindSortKey) { entry in
                EventCell(kind: entry.kind)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Name", value: \.path,
                        comparator: String.StandardComparator.localizedStandard) { entry in
                NameCell(entry: entry)
            }
            TableColumn("Folder", value: \.folderLabel,
                        comparator: String.StandardComparator.localizedStandard) { entry in
                Text(entry.folderLabel).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Device", value: \.partyDisplay,
                        comparator: String.StandardComparator.localizedStandard) { entry in
                PartyCell(entry: entry)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Time", value: \.time) { entry in
                TimeCell(time: entry.time, now: now)
            }
            .width(min: 70, ideal: 90)
        }
    }
}

// MARK: - Cells

/// The item's path — or, for a bulk entry, its count summary ("312 changes"),
/// set quieter to read as a summary line rather than a file.
///
/// A DELETED item's name is struck through — the universal idiom, and it
/// composes with every verb ("Delivered ~~name~~" = the tombstone reached
/// the device — the fact the old trash-glyph column never quite conveyed).
/// Strikethrough is visual-only, so the fact also rides the tooltip and the
/// accessibility label. This replaced the dedicated operation column
/// (2026-08-18): a glyph that read "pencil" on nearly every row carried no
/// information, and the one state it existed for is better marked on the
/// name itself. The operation FACT stays on the entry — the Change Type
/// filter and this styling both read it.
private struct NameCell: View {
    let entry: ActivityFeed.Entry

    var body: some View {
        let deleted = entry.operation == .deleted && entry.bulkCount == nil
        // Summaries and markers read quieter than files.
        let quiet = entry.bulkCount != nil || entry.kind.isMarker
        Text(entry.displayName)
            .strikethrough(deleted)
            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .truncationMode(.middle)
            .help(deleted ? "\(entry.displayName) — deleted" : entry.displayName)
            .accessibilityLabel(deleted ? "\(entry.displayName), deleted"
                                        : entry.displayName)
    }
}

/// The entry's other party — the device that MADE the change (modifiedBy),
/// not the transfer source (Syncthing pulls blocks from every replica that
/// has them; sources are plural, unexposed, and plumbing — authorship is the
/// human fact). Local detections say "This Mac"; inbound entries name the
/// originating device (— until the commit event identifies it).
private struct PartyCell: View {
    let entry: ActivityFeed.Entry

    var body: some View {
        Text(entry.partyDisplay)
            .foregroundStyle(.secondary)
    }
}

/// The entry's verb — glyph + word, reading as one fact. The visual rule
/// from the log redesign: arrows mean IN FLIGHT, checkmarks mean settled —
/// an arrow can never again be misread as activity on a finished item.
/// Color reinforces, never alone; the failed entry's tooltip carries the
/// error text. (Wording and glyph choices are provisional pending the
/// visual-language pass.)
private struct EventCell: View {
    let kind: ActivityFeed.Entry.Kind

    var body: some View {
        let display = Self.display(for: kind)
        HStack(spacing: 5) {
            Image(systemName: display.symbol)
                .foregroundStyle(display.color)
            Text(display.verb)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.verb)
        .help(display.detail)
    }

    private static func display(for kind: ActivityFeed.Entry.Kind)
        -> (symbol: String, color: Color, verb: String, detail: String) {
        switch kind {
        case .detected:
            ("magnifyingglass", .secondary, "Detected",
             "A change on this Mac was detected")
        case .sending:
            ("arrow.up.circle", .blue, "Sending",
             "The device is downloading this change")
        case .delivered:
            ("checkmark.circle", .green, "Delivered",
             "The device has this change")
        case .downloading:
            ("arrow.down.circle", .blue, "Downloading",
             "Receiving this change from another device")
        case .applied:
            ("checkmark.circle", .green, "Applied",
             "Applied on this Mac")
        case let .failed(message):
            ("exclamationmark.triangle", .red, "Failed",
             "Failed: \(message)")
        // Markers: the log's own lifecycle, set quiet (secondary) — they
        // are context, not activity.
        case .recordingStarted:
            ("record.circle", .secondary, "Recording started",
             "Recording started — activity from here on was witnessed")
        case .recordingPaused:
            ("pause.circle", .secondary, "Recording paused",
             "Recording paused — nothing was witnessed until the next start")
        case .connected:
            ("network", .secondary, "Connected",
             "Connected to Syncthing")
        case .disconnected:
            ("network.slash", .secondary, "Disconnected",
             "Lost the connection to Syncthing — nothing was witnessed until it returned")
        // Daemon events: what happened to a folder or device. Attention
        // colors only where something needs attention.
        case .devicePaused, .folderPaused:
            ("pause.circle", .orange, "Paused",
             "Paused — not syncing until resumed")
        case .deviceResumed, .folderResumed:
            ("play.circle", .secondary, "Resumed",
             "Resumed — syncing again")
        case .deviceOnline:
            ("antenna.radiowaves.left.and.right", .secondary, "Online",
             "The device connected")
        case .deviceOffline:
            ("antenna.radiowaves.left.and.right.slash", .secondary, "Offline",
             "The device disconnected")
        case let .folderError(message):
            ("exclamationmark.triangle", .red, "Stopped",
             "The folder stopped with an error: \(message)")
        case let .watchFailed(message):
            ("eye.trianglebadge.exclamationmark", .red, "Watch failed",
             "Changes are no longer noticed as they happen; only periodic rescans will: \(message)")
        case .watchRestored:
            ("eye", .secondary, "Watch restored",
             "Changes are noticed as they happen again")
        }
    }
}

private struct TimeCell: View {
    let time: Date
    /// Supplied by the view-level minute clock — cells are deliberately
    /// timer-free (see the body comment in ActivityView).
    let now: Date

    var body: some View {
        Text(RelativeTime.ago(time, now: now))
            .foregroundStyle(.secondary)
    }
}

/// The title-bar identity cluster: the app icon at full header height
/// spanning both text lines — "Syncthing Menu" bold over the live status in
/// regular secondary. One unit: no rule between the lines, hierarchy carried
/// by weight and color. Hosted as a titlebar ACCESSORY, not a toolbar item —
/// identity is content, not a tool, and toolbar items get the system's
/// capsule treatment (which clipped this cluster on macOS 27). Observes the
/// status model directly, so it updates itself.
struct ActivityHeaderView: View {
    @ObservedObject var status: SyncthingStatusModel

    var body: some View {
        HStack(spacing: 8) {
            AppIconImage.view(points: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Syncthing Menu")
                    .font(.system(size: 13, weight: .bold))
                Text("Syncthing: \(status.statusText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Constant width, everything pinned leading: the accessory's frame is
        // fixed at attach time, and content that resized with the status text
        // re-centered in it — the icon visibly wandered. Long status text
        // truncates instead of driving layout.
        .frame(width: 240, alignment: .leading)
        .padding(.leading, 8)
        .padding(.vertical, 4)
    }
}
