import Foundation
import Testing
@testable import SyncthingMenu

/// The log store in isolation: order, the window, the per-item index and
/// its episode state, removal, and update — the contracts the feed's O(1)
/// lookups rest on.
struct EntryLogTests {
    private func row(_ kind: ActivityFeed.Entry.Kind, _ path: String,
                     party: String? = nil, folder: String = "f") -> ActivityFeed.Entry {
        ActivityFeed.Entry(time: Date(), kind: kind, folderID: folder, folderLabel: "F",
                           path: path, operation: .modified, bulkCount: nil, party: party)
    }

    /// Newest first in the snapshot; the window evicts the oldest; the
    /// per-item index follows the newest row and forgets an evicted one.
    @Test func windowEvictsOldestAndSnapshotIsNewestFirst() {
        var log = EntryLog(capacity: 3)
        let a = row(.detected, "a"), b = row(.detected, "b"), c = row(.detected, "c")
        let d = row(.detected, "d")
        log.append(a); log.append(b); log.append(c)
        #expect(log.snapshot.map(\.path) == ["c", "b", "a"])
        log.append(d)
        #expect(log.count == 3)
        #expect(log.snapshot.map(\.path) == ["d", "c", "b"])
        #expect(log.newest(for: .init(folder: "f", path: "a")) == nil)
        #expect(log.newest(for: .init(folder: "f", path: "d"))?.id == d.id)
        #expect(log[a.id] == nil && log[d.id] == d)
    }

    /// The ring compacts without losing order: many more appends than the
    /// window, then the newest `capacity` in order.
    @Test func ringCompactsAcrossManyEvictions() {
        var log = EntryLog(capacity: 100)
        for i in 0..<10_000 { log.append(row(.detected, "p\(i)")) }
        #expect(log.count == 100)
        #expect(log.snapshot.first?.path == "p9999")
        #expect(log.snapshot.last?.path == "p9900")
        #expect(log.newest(for: .init(folder: "f", path: "p9950")) != nil)
        #expect(log.newest(for: .init(folder: "f", path: "p9899")) == nil)
    }

    /// Episode state: a detected/sending row starts a new episode (clears
    /// delivered parties); a delivered row records its party; the question
    /// "already delivered to X in this episode?" is per (item, party).
    @Test func deliveredPartiesTrackTheCurrentEpisode() {
        var log = EntryLog(capacity: 50)
        let key = EntryLog.ItemKey(folder: "f", path: "x")
        log.append(row(.detected, "x"))
        #expect(!log.isDelivered(key, to: "Laptop"))
        log.append(row(.delivered, "x", party: "Laptop"))
        #expect(log.isDelivered(key, to: "Laptop"))
        #expect(!log.isDelivered(key, to: "Desk"))
        log.append(row(.sending, "x", party: "Desk"))      // a new episode
        #expect(!log.isDelivered(key, to: "Laptop"))
        log.append(row(.delivered, "x", party: "Desk"))
        #expect(log.isDelivered(key, to: "Desk") && !log.isDelivered(key, to: "Laptop"))
    }

    /// Remove drops the row and forgets it as the item's newest; update
    /// enriches in place; non-item rows (empty path) never index.
    @Test func removeAndUpdateKeepTheIndexHonest() {
        var log = EntryLog(capacity: 50)
        let key = EntryLog.ItemKey(folder: "f", path: "x")
        let start = row(.downloading, "x")
        log.append(start)
        log.remove(id: start.id)
        #expect(log.isEmpty && log.newest(for: key) == nil)

        let applied = row(.applied, "x")
        log.append(applied)
        log.update(id: applied.id) { $0.party = "Laptop" }
        #expect(log.newest(for: key)?.party == "Laptop")
        #expect(log.snapshot[0].party == "Laptop")

        log.append(ActivityFeed.Entry.marker(.connected, time: Date()))
        #expect(log.count == 2)
        #expect(log.newest(for: key)?.id == applied.id)   // the marker is not an item
        log.remove(id: UUID())                             // unknown id: no-op
        #expect(log.count == 2)

        log.removeAll()
        #expect(log.isEmpty && log.snapshot.isEmpty && log.newest(for: key) == nil)
    }

    /// Removing a row that is NOT an item's newest leaves the index on the
    /// newest; removing the newest forgets the item (documented) until the
    /// next append for that path re-indexes it — and eviction of a newest
    /// row with delivered parties forgets those too.
    @Test func removingNonNewestKeepsTheIndex() {
        var log = EntryLog(capacity: 3)
        let key = EntryLog.ItemKey(folder: "f", path: "x")
        let first = row(.detected, "x")
        let second = row(.sending, "x", party: "Laptop")
        log.append(first)
        log.append(second)
        log.remove(id: first.id)
        #expect(log.newest(for: key)?.id == second.id)
        #expect(log.snapshot.map(\.id) == [second.id])

        log.remove(id: second.id)
        #expect(log.newest(for: key) == nil)
        log.append(row(.delivered, "x", party: "Laptop"))
        #expect(log.newest(for: key)?.kind == .delivered)
        #expect(log.isDelivered(key, to: "Laptop"))

        log.append(row(.detected, "y"))
        log.append(row(.detected, "z"))
        log.append(row(.detected, "w"))   // evicts x's delivered row
        #expect(log.newest(for: key) == nil && !log.isDelivered(key, to: "Laptop"))
    }
}
