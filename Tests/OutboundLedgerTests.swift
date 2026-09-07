import Foundation
import Testing
@testable import SyncthingMenu

/// The ledger's value-type policies, tested in isolation.
struct OutboundLedgerTests {
    /// `annotate` corrects an open loop's operation and kind WITHOUT
    /// restarting it: the open time — the sweep's staleness clock — is
    /// preserved, a nil kind keeps the existing one, and an untracked path
    /// is a no-op (never opens a loop).
    @Test func annotatePreservesOpenTimeAndFillsKind() {
        var ledger = OutboundLedger()
        let opened = Date(timeIntervalSinceReferenceDate: 100)
        ledger.track(folder: "f", path: "recovered", operation: .modified, at: opened)

        ledger.annotate(folder: "f", path: "recovered", operation: .deleted,
                        itemType: .directory)
        var closed = ledger.closeItems(in: "f", absentFrom: [])
        #expect(closed.count == 1)
        #expect(closed[0].item == .init(operation: .deleted, openedAt: opened,
                                        itemType: .directory))

        ledger.track(folder: "f", path: "typed", operation: .modified,
                     itemType: .file, at: opened)
        ledger.annotate(folder: "f", path: "typed", operation: .modified, itemType: nil)
        closed = ledger.closeItems(in: "f", absentFrom: [])
        #expect(closed[0].item.itemType == .file)

        ledger.annotate(folder: "f", path: "never-tracked", operation: .modified,
                        itemType: .file)
        #expect(!ledger.hasTrackedItems(in: "f"))
    }

    /// The cap drops the OLDEST live loop, in O(1) amortized through the
    /// insertion-order queue: closed loops and re-tracked paths leave stale
    /// queue entries that eviction skips, and a re-track counts as new.
    @Test func capEvictsOldestLiveLoop() {
        var ledger = OutboundLedger(capacity: 3)
        let t = { (s: TimeInterval) in Date(timeIntervalSinceReferenceDate: s) }
        ledger.track(folder: "f", path: "a", operation: .modified, at: t(1))
        ledger.track(folder: "f", path: "b", operation: .modified, at: t(2))
        ledger.track(folder: "f", path: "c", operation: .modified, at: t(3))
        ledger.track(folder: "f", path: "d", operation: .modified, at: t(4))   // evicts a
        #expect(!ledger.isTracking(folder: "f", path: "a"))
        #expect(ledger.isTracking(folder: "f", path: "b") && ledger.count == 3)

        _ = ledger.closeItem(folder: "f", path: "b")                          // stale entry
        ledger.track(folder: "f", path: "c", operation: .deleted, at: t(5))    // re-track: newest
        ledger.track(folder: "f", path: "e", operation: .modified, at: t(6))   // fills to 3
        ledger.track(folder: "f", path: "g", operation: .modified, at: t(7))   // evicts d, not c
        #expect(!ledger.isTracking(folder: "f", path: "d"))
        #expect(ledger.isTracking(folder: "f", path: "c") && ledger.isTracking(folder: "f", path: "e"))
        #expect(ledger.count == 3)

        // Many churned loops keep the queue bounded (compaction) and the
        // policy intact.
        for i in 0..<20_000 {
            ledger.track(folder: "f", path: "p\(i)", operation: .modified, at: t(100 + Double(i)))
            if i % 2 == 0 { _ = ledger.closeItem(folder: "f", path: "p\(i)") }
        }
        #expect(ledger.count == 3)
        #expect(ledger.isTracking(folder: "f", path: "p19999"))
    }
}
