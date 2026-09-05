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
}
