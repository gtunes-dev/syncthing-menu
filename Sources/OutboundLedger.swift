import Foundation

/// The activity feed's ledger of OPEN OUTBOUND LOOPS: local changes that have
/// been reported in the Activity log (a beginning) but whose delivery to
/// another device has not yet been confirmed (the ending). The feed's rule —
/// "every beginning deserves an ending" — makes this the list of endings
/// still owed.
///
/// Two tiers, matching the feed's two granularities (see `ActivityFeed`):
/// - **Tracked items** (human scale): individual paths, each carrying its
///   operation (so a delete's delivery can say so) and when we started
///   waiting. Closed per-item by any confirmation path.
/// - **Bulk counts** (machine scale): one integer per folder for changes
///   recorded in bulk — burst batches, index-update surpluses, and items
///   evicted from per-item tracking at the cap. No paths are retained, so
///   bulk loops can close only wholesale, on a folder-level catch-up.
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
    }

    /// Everything that was open for one folder, at the moment it closed.
    struct FolderClosure {
        /// Per-item loops, sorted by path for deterministic logging.
        let items: [(path: String, item: Item)]
        /// Changes that were only ever counted, never named.
        let bulkCount: Int
    }

    /// Per-item cap. Beyond it the OLDEST loop folds into its folder's bulk
    /// count — the console watches the newest activity, so the newest keeps
    /// per-item fidelity and the oldest degrades to the aggregate tier
    /// (its ending still arrives, as part of the folder's bulk closure).
    static let maxTrackedItems = 5000

    private var trackedItems: [String: [String: Item]] = [:]   // folder → path → item
    private var bulkCounts: [String: Int] = [:]                // folder → count
    private var bulkOpenedAt: [String: Date] = [:]             // oldest open bulk time
    private var totalTracked = 0

    // MARK: - Opening loops

    /// Open (or refresh — a re-detected path starts a new episode) one
    /// per-item loop.
    mutating func track(folder: String, path: String,
                        operation: ActivityFeed.Entry.Operation, at now: Date) {
        if trackedItems[folder]?[path] == nil {
            if totalTracked >= Self.maxTrackedItems { evictOldestIntoBulk() }
            totalTracked += 1
        }
        trackedItems[folder, default: [:]][path] = Item(operation: operation, openedAt: now)
    }

    /// Open (or grow) a folder's bulk loop by `count` changes.
    mutating func addBulk(folder: String, count: Int, at now: Date) {
        guard count > 0 else { return }
        bulkCounts[folder, default: 0] += count
        if bulkOpenedAt[folder] == nil { bulkOpenedAt[folder] = now }
    }

    private mutating func evictOldestIntoBulk() {
        var oldest: (folder: String, path: String, item: Item)?
        for (folder, items) in trackedItems {
            for (path, item) in items
            where oldest == nil || item.openedAt < oldest!.item.openedAt {
                oldest = (folder, path, item)
            }
        }
        guard let oldest else { return }
        trackedItems[oldest.folder]?.removeValue(forKey: oldest.path)
        totalTracked -= 1
        addBulk(folder: oldest.folder, count: 1, at: oldest.item.openedAt)
    }

    // MARK: - Closing loops

    /// Close EVERYTHING open for a folder — the full-catch-up closure ("the
    /// device needs nothing, so every open loop here is confirmed").
    /// Returns nil when nothing was open.
    mutating func closeFolder(_ folder: String) -> FolderClosure? {
        let items = trackedItems.removeValue(forKey: folder) ?? [:]
        totalTracked -= items.count
        let bulk = bulkCounts.removeValue(forKey: folder) ?? 0
        bulkOpenedAt[folder] = nil
        guard !items.isEmpty || bulk > 0 else { return nil }
        return FolderClosure(items: items.sorted { $0.key < $1.key }
                                          .map { (path: $0.key, item: $0.value) },
                             bulkCount: bulk)
    }

    /// Close the per-item loops ABSENT from a complete need list (the device
    /// no longer needs them → delivered). Bulk loops are untouched: absence
    /// can only be judged for paths we know.
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
        bulkCounts = [:]
        bulkOpenedAt = [:]
        totalTracked = 0
    }

    // MARK: - Queries

    /// Whether any per-item loop is open in the folder — gates the bounded
    /// remoteneed reads (no query when there is nothing it could close).
    func hasTrackedItems(in folder: String) -> Bool {
        !(trackedItems[folder]?.isEmpty ?? true)
    }

    /// Folders holding any loop opened before `cutoff` — the quiescence
    /// sweep's worklist. Sorted for deterministic probing.
    func folders(withLoopsOlderThan cutoff: Date) -> [String] {
        var stale = Set<String>()
        for (folder, items) in trackedItems
        where items.values.contains(where: { $0.openedAt < cutoff }) {
            stale.insert(folder)
        }
        for (folder, opened) in bulkOpenedAt
        where opened < cutoff && bulkCounts[folder, default: 0] > 0 {
            stale.insert(folder)
        }
        return stale.sorted()
    }
}
