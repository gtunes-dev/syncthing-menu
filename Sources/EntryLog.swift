import Foundation

/// The activity log's store: rows addressed by id, kept in arrival order,
/// bounded by ONE window size that is both the display cap and the memory
/// bound, plus a per-item index so the feed never scans rows to find "the
/// newest row for this path".
///
/// Why a store and not an array (2026-09-06): the feed used its display
/// array as working state — inserting each new row at the head and scanning
/// for a path's newest row to enrich or dedupe. Per item at machine scale
/// (tens of thousands of rows in one batch) that is quadratic, and the
/// bulk-coalescing paths that hid it were removed as a system choice the
/// user never asked for. Here every append, removal, update, and per-item
/// lookup is O(1) amortized; the newest-first snapshot for display is built
/// once per commit.
///
/// The per-item index carries the one piece of episode state the feed
/// needs beyond "newest row": which parties a path's CURRENT episode has
/// already been confirmed delivered to. A detected or sending row starts a
/// new episode (clears it); a delivered row records its party. The feed's
/// delivery confirmations overlap by design (remoteneed, the availability
/// check, catch-up, the sweep can each prove the same delivery), so this is
/// what keeps one delivered row per (path, device) per episode — and lets a
/// re-changed path log its next delivery (the Photos bug of 2026-08-17).
struct EntryLog {
    typealias Entry = ActivityFeed.Entry

    struct ItemKey: Hashable {
        let folder: String
        let path: String
    }

    private struct ItemIndex: Equatable {
        var newestID: UUID
        var deliveredTo: Set<String> = []
    }

    /// The window: rows kept, oldest evicted first beyond it.
    let capacity: Int

    private var rows: [UUID: Entry] = [:]
    /// Arrival order, oldest first from `head` (a ring: eviction advances
    /// `head` in O(1); the array is compacted once it is half dead).
    private var order: [UUID] = []
    private var head = 0
    /// File rows only (non-empty path): the newest row per item and the
    /// current episode's delivered parties.
    private var items: [ItemKey: ItemIndex] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { rows.count }
    var isEmpty: Bool { rows.isEmpty }

    /// Newest first — the display's array, built once per commit.
    var snapshot: [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(rows.count)
        var i = order.count - 1
        while i >= head {
            if let row = rows[order[i]] { result.append(row) }
            i -= 1
        }
        return result
    }

    subscript(id: UUID) -> Entry? { rows[id] }

    /// The newest row for an item, if any of its rows are still in the window.
    func newest(for key: ItemKey) -> Entry? {
        items[key].flatMap { rows[$0.newestID] }
    }

    /// Whether the item's CURRENT episode already has a delivered row for
    /// this party.
    func isDelivered(_ key: ItemKey, to party: String) -> Bool {
        items[key]?.deliveredTo.contains(party) ?? false
    }

    /// Append (newest); evict the oldest beyond capacity.
    mutating func append(_ entry: Entry) {
        rows[entry.id] = entry
        order.append(entry.id)
        if !entry.path.isEmpty {
            let key = ItemKey(folder: entry.folderID, path: entry.path)
            var index = items[key] ?? ItemIndex(newestID: entry.id)
            index.newestID = entry.id
            switch entry.kind {
            case .detected, .sending: index.deliveredTo = []
            case .delivered: if let party = entry.party { index.deliveredTo.insert(party) }
            default: break
            }
            items[key] = index
        }
        while rows.count > capacity, head < order.count {
            evictOldest()
        }
    }

    /// Remove one row (the same-batch collapse of a start into its finish,
    /// the un-fabrication of a recovered detection). Cost is the distance
    /// from the newest end — both callers remove a row appended moments
    /// before. CONSEQUENCE for the index: removing an item's NEWEST row
    /// forgets the item entirely (older rows for the path may remain in the
    /// window but `newest(for:)` reports nil and the episode's delivered
    /// parties are gone) until the next append for that path re-indexes it.
    /// Both callers append the replacement immediately, so nothing observes
    /// the gap; a future caller must not rely on `newest(for:)` after a
    /// bare `remove`.
    mutating func remove(id: UUID) {
        guard let entry = rows.removeValue(forKey: id) else { return }
        // Removals target recent rows: search from the newest end.
        var i = order.count - 1
        while i >= head {
            if order[i] == id { order.remove(at: i); break }
            i -= 1
        }
        forgetIfNewest(entry)
    }

    /// Enrich a row in place (author, operation, item kind — metadata only).
    mutating func update(id: UUID, _ body: (inout Entry) -> Void) {
        guard var entry = rows[id] else { return }
        body(&entry)
        rows[id] = entry
    }

    mutating func removeAll() {
        rows = [:]
        order = []
        head = 0
        items = [:]
    }

    private mutating func evictOldest() {
        let id = order[head]
        head += 1
        if let entry = rows.removeValue(forKey: id) { forgetIfNewest(entry) }
        if head > 64, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    private mutating func forgetIfNewest(_ entry: Entry) {
        guard !entry.path.isEmpty else { return }
        let key = ItemKey(folder: entry.folderID, path: entry.path)
        if items[key]?.newestID == entry.id { items[key] = nil }
    }
}
