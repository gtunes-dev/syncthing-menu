import Foundation

/// The activity feed's ledger of OPEN OUTBOUND LOOPS: local changes that have
/// been reported in the Activity log (a beginning) but whose delivery to
/// another device has not yet been confirmed (the ending). The feed's rule —
/// "every beginning deserves an ending" — makes this the list of endings
/// still owed.
///
/// Per item only (since 2026-09-06): each open loop is one path, carrying its
/// operation (so a delete's delivery can say so), its item kind, and when we
/// started waiting. The former bulk tier — folder-level counts closed
/// wholesale — went with the system-chosen coalescing it served. The cap is
/// a memory bound, not a display choice: beyond it the OLDEST loop is
/// dropped silently (its ending is omitted, never summarized). Eviction is
/// O(1) amortized through an insertion-order queue (a full scan per insert
/// would be quadratic at the cap — review finding, 2026-09-07).
///
/// Purely bookkeeping: the ledger never creates log entries — the feed
/// converts closures into delivered entries. A value type with no
/// dependencies, so its policies (cap, eviction) test in isolation.
struct OutboundLedger {
    /// One open per-item loop.
    struct Item: Equatable {
        let operation: ActivityFeed.Entry.Operation
        /// When WE began waiting (wall clock at tracking time, not the
        /// change event's own timestamp): staleness for the quiescence
        /// sweep measures how long a loop has been open.
        let openedAt: Date
        /// The item's kind, carried from the beginning to the delivered
        /// ending (nil = not known at tracking time).
        var itemType: ActivityFeed.Entry.ItemType? = nil
    }

    /// Memory bound on open loops (~100 bytes each). A machine-scale burst
    /// opens one per file; the oldest fold off silently beyond this.
    static let maxTrackedItems = 100_000

    let capacity: Int

    private var trackedItems: [String: [String: Item]] = [:]   // folder → path → item
    private var totalTracked = 0
    /// Insertion order for eviction: (folder, path, openedAt). An entry is
    /// live only while the tracked item still carries that `openedAt` — a
    /// closed or re-tracked path leaves a stale entry that eviction skips.
    /// (A re-track at an EQUAL `openedAt` — an injected fixed clock, or the
    /// same microsecond — keeps the old entry live, so that loop evicts at
    /// its original position; counts stay exact, only the order is off.)
    private var order: [(folder: String, path: String, openedAt: Date)] = []
    private var head = 0

    init(capacity: Int = OutboundLedger.maxTrackedItems) {
        self.capacity = capacity
    }

    // MARK: - Opening loops

    /// Open (or refresh — a re-detected path starts a new episode) one
    /// per-item loop.
    mutating func track(folder: String, path: String,
                        operation: ActivityFeed.Entry.Operation,
                        itemType: ActivityFeed.Entry.ItemType? = nil, at now: Date) {
        if trackedItems[folder]?[path] == nil {
            while totalTracked >= capacity, evictOldest() {}
            totalTracked += 1
        }
        trackedItems[folder, default: [:]][path] = Item(operation: operation, openedAt: now,
                                                        itemType: itemType)
        order.append((folder, path, now))
        compactOrderIfBloated()
    }

    /// Correct an open loop's facts without restarting it (the real change
    /// event arriving after a backstop recovery knows the operation and the
    /// item kind the recovery could only guess). No-op when nothing is open.
    mutating func annotate(folder: String, path: String,
                           operation: ActivityFeed.Entry.Operation,
                           itemType: ActivityFeed.Entry.ItemType?) {
        guard let item = trackedItems[folder]?[path] else { return }
        trackedItems[folder]?[path] = Item(operation: operation, openedAt: item.openedAt,
                                           itemType: itemType ?? item.itemType)
    }

    /// Drop the oldest live loop. Returns false when nothing is open.
    @discardableResult
    private mutating func evictOldest() -> Bool {
        while head < order.count {
            let entry = order[head]
            head += 1
            if let item = trackedItems[entry.folder]?[entry.path],
               item.openedAt == entry.openedAt {
                trackedItems[entry.folder]?.removeValue(forKey: entry.path)
                totalTracked -= 1
                return true
            }
        }
        return false
    }

    /// Keep the order queue proportional to the live loops: drop the
    /// consumed prefix once it dominates, and rebuild from the tracked items
    /// when stale entries (closed loops) have piled up.
    private mutating func compactOrderIfBloated() {
        if head > 1024, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
        if order.count - head > max(2 * totalTracked, 4096) {
            var live: [(folder: String, path: String, openedAt: Date)] = []
            live.reserveCapacity(totalTracked)
            for (folder, items) in trackedItems {
                for (path, item) in items { live.append((folder, path, item.openedAt)) }
            }
            live.sort { $0.openedAt < $1.openedAt }
            order = live
            head = 0
        }
    }

    // MARK: - Closing loops

    /// Close EVERYTHING open for a folder — the full-catch-up closure ("the
    /// device needs nothing, so every open loop here is confirmed"). Sorted
    /// by path for deterministic logging; empty when nothing was open.
    mutating func closeFolder(_ folder: String) -> [(path: String, item: Item)] {
        let items = trackedItems.removeValue(forKey: folder) ?? [:]
        totalTracked -= items.count
        return items.sorted { $0.key < $1.key }.map { (path: $0.key, item: $0.value) }
    }

    /// Close the per-item loops ABSENT from a complete need list (the device
    /// no longer needs them → delivered).
    mutating func closeItems(in folder: String, absentFrom needed: Set<String>)
        -> [(path: String, item: Item)] {
        guard let items = trackedItems[folder] else { return [] }
        let closed = items.filter { !needed.contains($0.key) }
        guard !closed.isEmpty else { return [] }
        for path in closed.keys { trackedItems[folder]?.removeValue(forKey: path) }
        totalTracked -= closed.count
        return closed.sorted { $0.key < $1.key }.map { (path: $0.key, item: $0.value) }
    }

    /// Close one per-item loop (an availability read confirmed this path).
    mutating func closeItem(folder: String, path: String) -> Item? {
        guard let item = trackedItems[folder]?.removeValue(forKey: path) else { return nil }
        totalTracked -= 1
        return item
    }

    mutating func removeAll() {
        trackedItems = [:]
        totalTracked = 0
        order = []
        head = 0
    }

    // MARK: - Queries

    var count: Int { totalTracked }

    /// Whether any loop is open in the folder — gates the bounded remoteneed
    /// reads (no query when there is nothing it could close).
    func hasTrackedItems(in folder: String) -> Bool {
        !(trackedItems[folder]?.isEmpty ?? true)
    }

    func isTracking(folder: String, path: String) -> Bool {
        trackedItems[folder]?[path] != nil
    }

    /// Folders holding any loop opened before `cutoff` — the quiescence
    /// sweep's worklist. Sorted for deterministic probing.
    func folders(withLoopsOlderThan cutoff: Date) -> [String] {
        var stale = Set<String>()
        for (folder, items) in trackedItems
        where items.values.contains(where: { $0.openedAt < cutoff }) {
            stale.insert(folder)
        }
        return stale.sorted()
    }
}
