import AppKit
import SwiftUI

/// The Activity window's content: the live activity feed, nothing else —
/// identity, global state, and the window's verbs live in the unified title
/// bar (`ActivityWindowController`), so the content area is pure data.
///
/// Column design (see the row model in `ActivityFeed`): a row's three
/// orthogonal facts each get their own column — Operation (static glyph)
/// with State (glyph, the ONLY dynamic column) immediately beside it so the
/// two read as one compound fact ("🗑 ↓" = remote delete applied), then the
/// prose columns. Status words live in tooltips + accessibility labels;
/// color reinforces, never alone. Motion in the table always means one
/// thing: a journey state advanced.
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
        let visible = feed.rows.filter(display.allows)
            .sorted(using: display.effectiveSortOrder)
        VStack(spacing: 0) {
            // A filtered feed must LOOK filtered — a quiet list under an
            // invisible filter reads as "syncing broke".
            if display.isActive {
                filterBar
                Divider()
            }
            Group {
                if visible.isEmpty {
                    emptyFeed(filtered: display.isActive && !feed.rows.isEmpty)
                } else if #available(macOS 14.0, *) {
                    CustomizableFeedTable(rows: visible, sortOrder: sortBinding)
                } else {
                    LegacyFeedTable(rows: visible, sortOrder: sortBinding)
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
    private var sortBinding: Binding<[KeyPathComparator<ActivityFeed.Row>]> {
        Binding {
            display.sortOrder
        } set: { new in
            if let first = new.first, first.keyPath == \ActivityFeed.Row.time,
               first.order == .forward,
               display.sortOrder.first?.keyPath != \ActivityFeed.Row.time {
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
    /// being here is normal — or that a filter is hiding what IS here.
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
/// matching the row model's two static facts — direction and operation; a
/// row shows iff its direction AND its operation are enabled; journey state
/// is a possible third group later) and the sort order (Finder-style single
/// sort column, Name as tiebreaker). Display-only and deliberately
/// transient: everything here resets with the app — a persisted hidden
/// filter is the "syncing broke" trap in durable form.
final class ActivityDisplayModel: ObservableObject {
    @Published var showLocal = true
    @Published var showRemote = true
    @Published var showModified = true
    @Published var showDeleted = true

    static let defaultSortOrder = [KeyPathComparator(\ActivityFeed.Row.time, order: .reverse)]

    /// The user's chosen sort (default: newest first). The Table binding
    /// writes it; display sorting applies `effectiveSortOrder`.
    @Published var sortOrder = ActivityDisplayModel.defaultSortOrder

    /// The applied sort: the chosen column, then Name as tiebreaker (unless
    /// Name IS the chosen column).
    var effectiveSortOrder: [KeyPathComparator<ActivityFeed.Row>] {
        var order = sortOrder
        if sortOrder.first?.keyPath != \ActivityFeed.Row.path {
            order.append(KeyPathComparator(\ActivityFeed.Row.path,
                                           comparator: String.StandardComparator.localizedStandard))
        }
        return order
    }

    var isActive: Bool {
        !(showLocal && showRemote && showModified && showDeleted)
    }

    func allows(_ row: ActivityFeed.Row) -> Bool {
        (row.isLocalOrigin ? showLocal : showRemote)
            && (row.operation == .deleted ? showDeleted : showModified)
    }

    /// Clear the FILTERS only (the filter bar's ✕ / Clear Filters buttons).
    func clear() {
        showLocal = true
        showRemote = true
        showModified = true
        showDeleted = true
    }

    /// Factory reset (the menu's ⌥ alternate): filters AND sort.
    func resetDisplay() {
        clear()
        sortOrder = Self.defaultSortOrder
    }

    /// The filter bar's full reading. Grammar: "Showing <what> [from
    /// <where>]" — <what> is the selected change type, or "changes" when
    /// both types are on and only the location constrains; an impossible
    /// selection (either group fully unchecked) reads "Showing no changes".
    var summary: String {
        if (!showModified && !showDeleted) || (!showLocal && !showRemote) {
            return "Showing no changes"
        }
        var text = "Showing "
        if showModified != showDeleted {
            text += showModified ? "adds & modifies" : "deletes"
        } else {
            text += "changes"
        }
        if showLocal != showRemote {
            text += showLocal ? " from this Mac" : " from other devices"
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
            Toggle("This Mac", isOn: $display.showLocal)
            Toggle("Other Devices", isOn: $display.showRemote)
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
    let rows: [ActivityFeed.Row]
    @Binding var sortOrder: [KeyPathComparator<ActivityFeed.Row>]
    @State private var customization: TableColumnCustomization<ActivityFeed.Row>

    init(rows: [ActivityFeed.Row], sortOrder: Binding<[KeyPathComparator<ActivityFeed.Row>]>) {
        self.rows = rows
        self._sortOrder = sortOrder
        if let data = UserDefaults.standard.data(forKey: ActivityColumnStore.defaultsKey),
           let saved = try? JSONDecoder().decode(
               TableColumnCustomization<ActivityFeed.Row>.self, from: data) {
            _customization = State(initialValue: saved)
        } else {
            _customization = State(initialValue: .init())
        }
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder, columnCustomization: $customization) {
            // Single-SPACE titles: an empty-string title suppresses the
            // native sort caret entirely; a space reads as an empty header
            // while giving the indicator an anchor when the column sorts.
            // Empty-title glyph columns at 40pt: the native sort caret
            // needs header room — it silently disappears below ~33-40pt
            // (bisected empirically on macOS 27; 24 and 32 suppress it, 40
            // shows it). The title text is irrelevant. Glyphs center in the
            // wider cells.
            TableColumn("", value: \.operationSortKey) { row in
                OperationGlyph(operation: row.operation)
            }
            .width(40)
            TableColumn("", value: \.stateSortKey) { row in
                StatusGlyph(state: row.state)
            }
            .width(40)
            TableColumn("Name", value: \.path,
                        comparator: String.StandardComparator.localizedStandard) { row in
                NameCell(path: row.path)
            }
            .customizationID("name")
            TableColumn("Folder", value: \.folderLabel,
                        comparator: String.StandardComparator.localizedStandard) { row in
                Text(row.folderLabel).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
            .customizationID("folder")
            TableColumn("Changed By", value: \.originDisplay,
                        comparator: String.StandardComparator.localizedStandard) { row in
                OriginCell(row: row)
            }
            .width(min: 60, ideal: 90)
            .customizationID("from")
            TableColumn("Time", value: \.time) { row in
                TimeCell(time: row.time)
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
    let rows: [ActivityFeed.Row]
    @Binding var sortOrder: [KeyPathComparator<ActivityFeed.Row>]

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            // Empty-title glyph columns at 40pt: the native sort caret
            // needs header room — it silently disappears below ~33-40pt
            // (bisected empirically on macOS 27; 24 and 32 suppress it, 40
            // shows it). The title text is irrelevant. Glyphs center in the
            // wider cells.
            TableColumn("", value: \.operationSortKey) { row in
                OperationGlyph(operation: row.operation)
            }
            .width(40)
            TableColumn("", value: \.stateSortKey) { row in
                StatusGlyph(state: row.state)
            }
            .width(40)
            TableColumn("Name", value: \.path,
                        comparator: String.StandardComparator.localizedStandard) { row in
                NameCell(path: row.path)
            }
            TableColumn("Folder", value: \.folderLabel,
                        comparator: String.StandardComparator.localizedStandard) { row in
                Text(row.folderLabel).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Changed By", value: \.originDisplay,
                        comparator: String.StandardComparator.localizedStandard) { row in
                OriginCell(row: row)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Time", value: \.time) { row in
                TimeCell(time: row.time)
            }
            .width(min: 70, ideal: 90)
        }
    }
}

// MARK: - Cells

/// What happened to the file — static identity, so a quiet secondary glyph.
private struct OperationGlyph: View {
    let operation: ActivityFeed.Row.Operation

    var body: some View {
        Image(systemName: operation == .deleted ? "trash" : "pencil")
            .foregroundStyle(.secondary)
            .accessibilityLabel(operation == .deleted ? "Deleted" : "Modified")
            .help(operation == .deleted ? "Deleted" : "Modified")
            .frame(maxWidth: .infinity)
    }
}

private struct NameCell: View {
    let path: String

    var body: some View {
        Text(path)
            .truncationMode(.middle)
            .help(path)
    }
}

/// Whose change it is — the device that MADE the change (modifiedBy), not
/// the transfer source (Syncthing pulls blocks from every replica that has
/// them; sources are plural, unexposed, and plumbing — authorship is the
/// human fact). Local edits say "This Mac"; inbound rows name the
/// originating device (— until the commit event identifies it).
private struct OriginCell: View {
    let row: ActivityFeed.Row

    var body: some View {
        Text(row.originDisplay)
            .foregroundStyle(.secondary)
    }
}

/// The journey state — one glyph, sitting beside the operation glyph so the
/// pair reads as a compound fact. Every state has a distinct silhouette;
/// color reinforces (green settled/active, red failed, gray waiting/void),
/// never alone. The word lives in the tooltip and accessibility label; the
/// failed state's tooltip carries the error text.
private struct StatusGlyph: View {
    let state: ActivityFeed.Row.JourneyState

    var body: some View {
        let display = Self.display(for: state)
        Image(systemName: display.symbol)
            .foregroundStyle(display.color)
            .accessibilityLabel(display.label)
            .help(display.detail)
            .frame(maxWidth: .infinity)
    }

    private static func display(for state: ActivityFeed.Row.JourneyState)
        -> (symbol: String, color: Color, label: String, detail: String) {
        switch state {
        case .pending:
            ("clock", .secondary, "Pending",
             "Waiting to sync to another device")
        case .uploading:
            ("arrow.triangle.2.circlepath", .green, "Syncing out",
             "Another device is downloading this change")
        case .synced:
            ("arrow.up", .green, "Synced",
             "Delivered to at least one other device")
        case .superseded:
            ("clock.badge.xmark", .secondary, "Superseded",
             "Replaced by a newer change before it synced")
        case .syncing:
            ("arrow.triangle.2.circlepath", .green, "Syncing",
             "Being applied on this Mac")
        case .applied:
            ("arrow.down", .green, "Applied",
             "Applied on this Mac")
        case let .failed(message):
            ("exclamationmark.triangle", .red, "Failed",
             "Failed: \(message)")
        }
    }
}

private struct TimeCell: View {
    let time: Date

    var body: some View {
        // Coarse "… ago", kept live by the minute — same treatment as the
        // Settings cards' "Last checked" line.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(RelativeTime.ago(time, now: context.date))
                .foregroundStyle(.secondary)
        }
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

    /// The app icon pre-sized to display size, so AppKit's rep matching picks
    /// the exact 64px representation — SwiftUI `.resizable()` resampling from
    /// the largest rep is what made the 32pt icon look dithered. The icon's
    /// glow style is inherently soft at this size; accepted (a flat re-render
    /// was tried 2026-07-21 and looked too unlike the app icon).
    private static let icon: NSImage = {
        guard let image = NSApp.applicationIconImage?.copy() as? NSImage else { return NSImage() }
        image.size = NSSize(width: 32, height: 32)
        return image
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon)
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
