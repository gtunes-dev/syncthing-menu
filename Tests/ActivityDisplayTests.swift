import Foundation
import Testing
@testable import SyncthingMenu

/// Pure-logic tests for the Activity window's display layer: the filter
/// predicate and its bar grammar, the sort-order tiebreaker, the entry sort
/// keys (pinning the decided attention order), and the shared status model's
/// text priority chain.
struct ActivityDisplayTests {

    private func makeEntry(kind: ActivityFeed.Entry.Kind = .detected,
                           op: ActivityFeed.Entry.Operation = .modified,
                           path: String = "a.txt",
                           time: Date = Date(timeIntervalSince1970: 0),
                           bulkCount: Int? = nil,
                           party: String? = nil) -> ActivityFeed.Entry {
        ActivityFeed.Entry(time: time, kind: kind, folderID: "f", folderLabel: "F",
                           path: path, operation: op, bulkCount: bulkCount, party: party)
    }

    // MARK: Filter predicate

    /// An entry shows iff its direction box AND its operation box are checked
    /// — the full truth table across both groups. Direction is a property of
    /// the verb: detected is outbound, the item kinds are inbound.
    @Test func filterTruthTable() {
        let model = ActivityDisplayModel()
        let outboundModify = makeEntry(kind: .detected, op: .modified)
        let outboundDelete = makeEntry(kind: .detected, op: .deleted)
        let inboundModify = makeEntry(kind: .applied, op: .modified)
        let inboundDelete = makeEntry(kind: .applied, op: .deleted)

        #expect(model.allows(outboundModify) && model.allows(outboundDelete)
                && model.allows(inboundModify) && model.allows(inboundDelete))
        #expect(!model.isActive)

        model.showOutbound = false
        #expect(!model.allows(outboundModify) && !model.allows(outboundDelete))
        #expect(model.allows(inboundModify) && model.allows(inboundDelete))
        #expect(model.isActive)

        model.showOutbound = true
        model.showDeleted = false
        #expect(model.allows(outboundModify) && model.allows(inboundModify))
        #expect(!model.allows(outboundDelete) && !model.allows(inboundDelete))

        model.showModified = false
        #expect(!model.allows(outboundModify) && !model.allows(inboundDelete))
    }

    /// Name search: case-insensitive substring over the path, ANDed with the
    /// checkbox groups. Bulk entries carry no path, so a non-empty search
    /// never matches them (the aggregate tier's documented boundary).
    @Test func searchMatchesPathsCaseInsensitively() {
        let model = ActivityDisplayModel()
        let photo = makeEntry(path: "Photos/IMG_2041.jpeg")
        let note = makeEntry(path: "notes.md")
        let bulk = makeEntry(path: "", bulkCount: 312)

        #expect(model.allows(bulk))          // empty search hides nothing
        model.searchText = "img_20"
        #expect(model.allows(photo))
        #expect(!model.allows(note))
        #expect(!model.allows(bulk))
        #expect(model.isActive)

        // Search ANDs with the groups: a matching entry still needs its
        // direction box checked.
        model.showOutbound = false
        #expect(!model.allows(photo))

        model.clear()
        #expect(model.searchText.isEmpty)
        #expect(!model.isActive)
    }

    /// The bar grammar's search clause.
    @Test func summaryIncludesSearchClause() {
        let model = ActivityDisplayModel()
        model.searchText = "img"
        #expect(model.summary == "Showing changes matching “img”")
        model.showDeleted = false
        #expect(model.summary == "Showing adds & modifies matching “img”")
    }

    /// Bulk entries summarize their count in the Name column; per-item
    /// entries show their path.
    @Test func displayNameSummarizesBulkEntries() {
        #expect(makeEntry(bulkCount: 1).displayName == "1 change")
        #expect(makeEntry(bulkCount: 312).displayName == "312 changes")
        #expect(makeEntry(path: "a.txt").displayName == "a.txt")
    }

    /// Direction is a property of the verb: detections and the
    /// transfer/delivery kinds are outbound, the item kinds inbound.
    @Test func directionFollowsKind() {
        #expect(ActivityFeed.Entry.Kind.detected.isOutbound)
        #expect(ActivityFeed.Entry.Kind.sending.isOutbound)
        #expect(ActivityFeed.Entry.Kind.delivered.isOutbound)
        #expect(!ActivityFeed.Entry.Kind.downloading.isOutbound)
        #expect(!ActivityFeed.Entry.Kind.applied.isOutbound)
        #expect(!ActivityFeed.Entry.Kind.failed("x").isOutbound)
    }

    /// The bar grammar, verified against the agreed example set.
    @Test func filterSummaryGrammar() {
        let model = ActivityDisplayModel()

        model.showModified = false
        model.showDeleted = false
        #expect(model.summary == "Showing no changes")

        model.clear()
        model.showOutbound = false
        model.showInbound = false
        #expect(model.summary == "Showing no changes")

        model.clear()
        model.showDeleted = false
        #expect(model.summary == "Showing adds & modifies")

        model.showInbound = false
        #expect(model.summary == "Showing adds & modifies from this Mac")

        model.showInbound = true
        model.showOutbound = false
        #expect(model.summary == "Showing adds & modifies from other devices")

        model.clear()
        model.showModified = false
        #expect(model.summary == "Showing deletes")

        model.clear()
        model.showOutbound = false
        #expect(model.summary == "Showing changes from other devices")

        model.showOutbound = true
        model.showInbound = false
        #expect(model.summary == "Showing changes from this Mac")
    }

    /// `clear` restores filters only; `resetDisplay` also restores the sort.
    @Test func clearVersusResetDisplay() {
        let model = ActivityDisplayModel()
        model.showDeleted = false
        model.sortOrder = [KeyPathComparator(\ActivityFeed.Entry.folderLabel)]

        model.clear()
        #expect(!model.isActive)
        #expect(model.sortOrder.first?.keyPath == \ActivityFeed.Entry.folderLabel)

        model.resetDisplay()
        #expect(model.sortOrder == ActivityDisplayModel.defaultSortOrder)
    }

    // MARK: Sort order

    /// Name is appended as tiebreaker unless Name IS the primary sort.
    @Test func nameTiebreakerAppendedExceptWhenPrimary() {
        let model = ActivityDisplayModel()
        #expect(model.effectiveSortOrder.count == 2)
        #expect(model.effectiveSortOrder.last?.keyPath == \ActivityFeed.Entry.path)

        model.sortOrder = [KeyPathComparator(\ActivityFeed.Entry.path)]
        #expect(model.effectiveSortOrder.count == 1)
    }

    /// Default sort shows newest first.
    @Test func defaultSortIsNewestFirst() {
        let old = makeEntry(path: "old.txt")
        let newer = makeEntry(path: "new.txt", time: Date(timeIntervalSince1970: 100))
        let sorted = [old, newer].sorted(using: ActivityDisplayModel().effectiveSortOrder)
        #expect(sorted.first?.path == "new.txt")
    }

    // MARK: Entry sort keys

    /// Pins the decided attention order: ascending Event puts problems first,
    /// then in-flight, then observations, then settled outcomes.
    @Test func kindSortKeyFollowsAttentionOrder() {
        let kinds: [ActivityFeed.Entry.Kind] =
            [.failed("boom"), .downloading, .sending, .detected,
             .delivered, .applied]
        let keys = kinds.map { makeEntry(kind: $0).kindSortKey }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    /// The Device column's display string: the entry's party, with the
    /// honest "—" while an author is still unidentified.
    @Test func partyDisplayVariants() {
        #expect(makeEntry(party: "This Mac").partyDisplay == "This Mac")
        #expect(makeEntry(party: "Laptop").partyDisplay == "Laptop")
        #expect(makeEntry(party: nil).partyDisplay == "—")
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

    /// The self-managed disconnected states: each issue renders its own status
    /// line, none of them smooth (they aren't activity), and a connected
    /// self-managed daemon uses the ordinary running grammar.
    @Test func selfManagedStatusTexts() {
        let model = SyncthingStatusModel()

        model.update(.selfManaged(.notConfigured))
        #expect(model.statusText == "Not configured")
        #expect(model.display == .notConfigured)

        model.update(.selfManaged(.connecting))
        #expect(model.statusText == "Connecting…")

        model.update(.selfManaged(.unreachable))
        #expect(model.statusText == "Not reachable")
        #expect(model.summaryText == "Syncthing is not reachable at the configured address")

        model.update(.selfManaged(.keyRejected))
        #expect(model.statusText == "API key rejected")
        #expect(!model.isRunning)

        // Connected: the same running grammar as managed mode.
        model.update(.running(activity: .syncing, paused: false, attention: false))
        #expect(model.statusText == "Syncing…")
        #expect(model.isRunning)
    }

    /// The tooltip/accessibility sentences track the same display state as
    /// the short grammar — every surface tells the same story.
    @Test func summaryTextMatchesDisplay() {
        let model = SyncthingStatusModel()
        #expect(model.summaryText == "Syncthing is not running")

        model.update(.running(activity: .syncing, paused: false, attention: false))
        #expect(model.summaryText == "Syncthing is syncing")

        model.update(.running(activity: .syncing, paused: true, attention: false))
        #expect(model.summaryText == "Syncthing is paused")

        model.update(.failed("boom"))
        #expect(model.summaryText == "Syncthing failed — boom")
    }

    // MARK: Display smoothing

    private func running(_ activity: SyncActivity,
                         paused: Bool = false,
                         attention: Bool = false) -> SyncthingStatusModel.Phase {
        .running(activity: activity, paused: paused, attention: attention)
    }

    /// Escalation renders immediately at every step — a delay here would
    /// recreate the missed-flash bug the smoothing exists to fix.
    @Test func escalationIsImmediate() {
        let model = SyncthingStatusModel()
        model.update(running(.idle))
        #expect(model.display == .running)
        model.update(running(.scanning))
        #expect(model.display == .scanning)
        model.update(running(.syncing))
        #expect(model.display == .syncing)
    }

    /// While a Syncthing update is applying, the display reads Updating…
    /// through the whole window's churn (running → stopped → starting) — but a
    /// real failure still surfaces, and clearing the flag restores truth.
    @Test func updatingMasksChurnButNotFailure() {
        let model = SyncthingStatusModel()
        model.update(running(.scanning))
        model.update(updatingSyncthing: true)
        #expect(model.display == .updating)
        #expect(model.statusText == "Updating…")

        model.update(.notRunning)                  // re-root: daemon stopping
        #expect(model.display == .updating)
        model.update(.starting)                    // re-root: fresh spawn
        #expect(model.display == .updating)

        model.update(.failed("Syncthing exited (code 1)"))
        #expect(model.display == .failed("Syncthing exited (code 1)"))

        model.update(.starting)
        model.update(running(.idle))
        model.update(updatingSyncthing: false)
        #expect(model.display == .running)
    }

    /// A sub-second episode stays visible: the drop back waits for BOTH the
    /// minimum-visibility window and the debounce, then lands on the current
    /// truth.
    @Test func dropWaitsForMinimumVisibilityAndDebounce() {
        let model = SyncthingStatusModel()
        var time = Date(timeIntervalSinceReferenceDate: 0)
        model.now = { time }

        model.update(running(.syncing))
        model.update(running(.idle))          // truth drops right away
        #expect(model.display == .syncing)    // held

        time += 2.9
        model.applyPendingDrop()
        #expect(model.display == .syncing)    // < minimumVisibility

        time += 0.2                            // 3.1s shown, 3.1s below
        model.applyPendingDrop()
        #expect(model.display == .running)
    }

    /// After minimum visibility is long satisfied, a drop still debounces:
    /// truth must stay below the shown level for `dropDebounce`.
    @Test func dropDebouncesAfterLongEpisode() {
        let model = SyncthingStatusModel()
        var time = Date(timeIntervalSinceReferenceDate: 0)
        model.now = { time }

        model.update(running(.syncing))
        time += 60                             // a real, long sync episode
        model.update(running(.idle))
        time += 1.4
        model.applyPendingDrop()
        #expect(model.display == .syncing)    // debounce not elapsed
        time += 0.2
        model.applyPendingDrop()
        #expect(model.display == .running)
    }

    /// Back-to-back episodes (folder B starts shortly after folder A ends)
    /// read as one continuous state — the pending drop is cancelled, and no
    /// intermediate flicker is ever displayed.
    @Test func reescalationCancelsPendingDrop() {
        let model = SyncthingStatusModel()
        var time = Date(timeIntervalSinceReferenceDate: 0)
        model.now = { time }

        model.update(running(.syncing))
        time += 10
        model.update(running(.idle))
        time += 1.0                            // within the debounce gap
        model.update(running(.syncing))
        #expect(model.display == .syncing)

        time += 30                             // the cancelled drop never fires
        model.applyPendingDrop()
        #expect(model.display == .syncing)
    }

    /// Truth moving between LOWER levels keeps the original below-anchor: the
    /// debounce measures time below the shown level. The drop lands on the
    /// truth at drop time, not the level truth first dropped to.
    @Test func dropLandsOnCurrentTruth() {
        let model = SyncthingStatusModel()
        var time = Date(timeIntervalSinceReferenceDate: 0)
        model.now = { time }

        model.update(running(.syncing))
        time += 10
        model.update(running(.idle))
        time += 1.0
        model.update(running(.scanning))       // still below syncing
        time += 0.6                            // 1.6s below syncing in total
        model.applyPendingDrop()
        #expect(model.display == .scanning)
    }

    /// Paused, attention, failure, and shutdown bypass smoothing in BOTH
    /// directions: they render immediately, and no held activity survives
    /// them — when the override clears, display restarts from current truth.
    @Test func overridesBypassSmoothingAndResetHold() {
        let model = SyncthingStatusModel()
        var time = Date(timeIntervalSinceReferenceDate: 0)
        model.now = { time }

        model.update(running(.syncing))
        model.update(running(.syncing, paused: true))
        #expect(model.display == .paused)      // immediate, despite the hold

        model.update(running(.idle))           // unpaused, now idle
        #expect(model.display == .running)     // syncing hold did not survive

        model.update(running(.syncing))
        model.update(.failed("gone"))
        #expect(model.display == .failed("gone"))
        model.update(.notRunning)
        #expect(model.display == .notRunning)
    }
}
