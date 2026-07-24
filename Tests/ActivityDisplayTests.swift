import Foundation
import Testing
@testable import SyncthingMenu

/// Pure-logic tests for the Activity window's display layer: the filter
/// predicate and its bar grammar, the sort-order tiebreaker, the row sort
/// keys (pinning the decided attention order), and the shared status model's
/// text priority chain.
struct ActivityDisplayTests {

    private func makeRow(op: ActivityFeed.Row.Operation = .modified,
                         state: ActivityFeed.Row.JourneyState = .pending,
                         isLocal: Bool = true,
                         path: String = "a.txt",
                         origin: String? = nil) -> ActivityFeed.Row {
        ActivityFeed.Row(time: Date(timeIntervalSince1970: 0), folderID: "f",
                         folderLabel: "F", path: path, isLocalOrigin: isLocal,
                         operation: op, state: state, origin: origin,
                         episodeOpen: false, sequence: nil, uploadRefreshedAt: nil)
    }

    // MARK: Filter predicate

    /// A row shows iff its direction box AND its operation box are checked —
    /// the full truth table across both groups.
    @Test func filterTruthTable() {
        let model = ActivityDisplayModel()
        let localModify = makeRow(op: .modified, isLocal: true)
        let localDelete = makeRow(op: .deleted, isLocal: true)
        let remoteModify = makeRow(op: .modified, isLocal: false)
        let remoteDelete = makeRow(op: .deleted, isLocal: false)

        #expect(model.allows(localModify) && model.allows(localDelete)
                && model.allows(remoteModify) && model.allows(remoteDelete))
        #expect(!model.isActive)

        model.showLocal = false
        #expect(!model.allows(localModify) && !model.allows(localDelete))
        #expect(model.allows(remoteModify) && model.allows(remoteDelete))
        #expect(model.isActive)

        model.showLocal = true
        model.showDeleted = false
        #expect(model.allows(localModify) && model.allows(remoteModify))
        #expect(!model.allows(localDelete) && !model.allows(remoteDelete))

        model.showModified = false
        #expect(!model.allows(localModify) && !model.allows(remoteDelete))
    }

    /// The bar grammar, verified against the agreed example set.
    @Test func filterSummaryGrammar() {
        let model = ActivityDisplayModel()

        model.showModified = false
        model.showDeleted = false
        #expect(model.summary == "Showing no changes")

        model.clear()
        model.showLocal = false
        model.showRemote = false
        #expect(model.summary == "Showing no changes")

        model.clear()
        model.showDeleted = false
        #expect(model.summary == "Showing adds & modifies")

        model.showRemote = false
        #expect(model.summary == "Showing adds & modifies from this Mac")

        model.showRemote = true
        model.showLocal = false
        #expect(model.summary == "Showing adds & modifies from other devices")

        model.clear()
        model.showModified = false
        #expect(model.summary == "Showing deletes")

        model.clear()
        model.showLocal = false
        #expect(model.summary == "Showing changes from other devices")

        model.showLocal = true
        model.showRemote = false
        #expect(model.summary == "Showing changes from this Mac")
    }

    /// `clear` restores filters only; `resetDisplay` also restores the sort.
    @Test func clearVersusResetDisplay() {
        let model = ActivityDisplayModel()
        model.showDeleted = false
        model.sortOrder = [KeyPathComparator(\ActivityFeed.Row.folderLabel)]

        model.clear()
        #expect(!model.isActive)
        #expect(model.sortOrder.first?.keyPath == \ActivityFeed.Row.folderLabel)

        model.resetDisplay()
        #expect(model.sortOrder == ActivityDisplayModel.defaultSortOrder)
    }

    // MARK: Sort order

    /// Name is appended as tiebreaker unless Name IS the primary sort.
    @Test func nameTiebreakerAppendedExceptWhenPrimary() {
        let model = ActivityDisplayModel()
        #expect(model.effectiveSortOrder.count == 2)
        #expect(model.effectiveSortOrder.last?.keyPath == \ActivityFeed.Row.path)

        model.sortOrder = [KeyPathComparator(\ActivityFeed.Row.path)]
        #expect(model.effectiveSortOrder.count == 1)
    }

    /// Default sort shows newest first.
    @Test func defaultSortIsNewestFirst() {
        let old = makeRow(path: "old.txt")
        var newer = makeRow(path: "new.txt")
        newer.time = Date(timeIntervalSince1970: 100)
        let sorted = [old, newer].sorted(using: ActivityDisplayModel().effectiveSortOrder)
        #expect(sorted.first?.path == "new.txt")
    }

    // MARK: Row sort keys

    /// Pins the decided attention order: ascending Status puts problems first,
    /// settled outcomes last.
    @Test func stateSortKeyFollowsAttentionOrder() {
        let states: [ActivityFeed.Row.JourneyState] =
            [.failed("boom"), .syncing, .uploading, .pending, .superseded, .applied, .synced]
        let keys = states.map { makeRow(state: $0).stateSortKey }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    @Test func operationSortKeyOrdersModifiesFirst() {
        #expect(makeRow(op: .modified).operationSortKey < makeRow(op: .deleted).operationSortKey)
    }

    /// The Changed By display string: authorship, with honest fallbacks.
    @Test func originDisplayVariants() {
        #expect(makeRow(isLocal: true).originDisplay == "This Mac")
        #expect(makeRow(isLocal: false, origin: "Laptop").originDisplay == "Laptop")
        #expect(makeRow(isLocal: false, origin: nil).originDisplay == "—")
    }

    // MARK: SyncthingStatusModel

    /// The one-line status grammar and its priority chain: attention > paused
    /// > syncing > scanning > running — the same order as the menu status row.
    @Test func statusTextPriorityChain() {
        let model = SyncthingStatusModel()
        #expect(model.statusText == "Not running")
        #expect(!model.isRunning)

        model.update(.starting)
        #expect(model.statusText == "Starting…")

        model.update(.running(activity: .idle, paused: false, attention: false))
        #expect(model.statusText == "Running")
        #expect(model.isRunning)
        #expect(!model.isPaused)

        model.update(.running(activity: .scanning, paused: false, attention: false))
        #expect(model.statusText == "Scanning…")

        model.update(.running(activity: .syncing, paused: false, attention: false))
        #expect(model.statusText == "Syncing…")

        model.update(.running(activity: .syncing, paused: true, attention: false))
        #expect(model.statusText == "Paused")
        #expect(model.isPaused)

        model.update(.running(activity: .syncing, paused: true, attention: true))
        #expect(model.statusText == "Can't access some folders")

        model.update(.failed("daemon exploded"))
        #expect(model.statusText == "daemon exploded")
        #expect(!model.isRunning)
    }
}
