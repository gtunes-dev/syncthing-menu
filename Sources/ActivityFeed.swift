import Foundation

/// Live activity log for the Activity window: an append-only record of the
/// LOGICAL sync events witnessed while the window is open, newest first.
///
/// ## Intent
///
/// The window narrates, in real time, the sync lifecycle of every file whose
/// activity this device witnesses while the window is open — so the person
/// at the console can answer "what is happening, and did my changes make
/// it?" Principles (settled 2026-08-17):
///
/// 1. **Rows are conclusions, not API events.** A log entry states something
///    we are prepared to defend ("Muninn has this file now"); several API
///    signals may fund one conclusion, and no API event appears raw.
/// 2. **Lag, never lie — degrade by omission, never fabrication.** An
///    unconfirmable claim is silence, not a guess.
/// 3. **Every beginning deserves an ending — where one is owed.** A
///    detected/sending entry that never resolves reads as "sync is broken".
///    Open loops are tracked in the `OutboundLedger` and closed by events
///    when possible and by the quiescence sweep when an event was missed.
///    An ending is owed only where delivery is POSSIBLE IN PRINCIPLE: the
///    folder sends (not receive-only) and at least one other device shares
///    it (`deliverableFolders`). Elsewhere a detected entry stands alone —
///    still true, promising nothing. This gate is load-bearing for
///    receive-only folders: their local additions are excluded from the
///    global index, so a remote reads completion 100 immediately and a
///    naive loop would close as a FALSE "delivered" (found in the
///    2026-08-17 case enumeration).
/// 4. **Per-replica truth only where the direction supports it.** Outbound
///    is genuinely per-replica (our own index knows what each device needs
///    and has). Inbound "from a replica" is NOT a well-posed question —
///    blocks of one file are pulled from every replica that has them — so
///    the inbound party is the change's AUTHOR, never a transfer source.
/// 5. **Narrative granularity matches witnessing granularity — and reading
///    scale.** Per-item entries at human scale; folder-level BULK entries at
///    machine scale (a Photos-style churn of thousands), where per-item
///    events are unreadable AND undetectable (the event ring overflows by
///    arithmetic). Beginnings and endings always pair at the granularity
///    the user saw: per-item detected → per-item delivered; a bulk
///    "N changes" detected → a bulk "N changes" delivered.
///
/// ## The entries
///
/// Each entry is an immutable statement that something HAPPENED — a verb, an
/// item (or a bulk count), a party, a time. Times are event times, never
/// re-stamped; there is no "superseded" (a newer change is simply a newer
/// entry); eviction is plain oldest-first at the cap; entries are immutable
/// in STATE but enrichable in METADATA (an applied entry gains its author).
///
/// entry kind   | party            | evidence
/// -------------|------------------|---------------------------------------
/// detected     | This Mac         | LocalChangeDetected; or recovered BY NAME from LocalIndexUpdated's filenames (the burst backstop — batched, so it survives the ring overflow that eats per-file events); or, as a BULK entry, an over-threshold burst batch / an over-threshold unnamed backstop surplus (small unnamed surpluses are suppressed as slop)
/// sending      | recipient        | path APPEARS in the device's RemoteDownloadProgress state map
/// delivered    | recipient        | path DISAPPEARS from the state map + our index shows the device has it; or the path is absent from a COMPLETE remoteneed list; or a folder-level catch-up closes every open loop (per-item AND bulk, at their own granularities); or the quiescence sweep confirms a stale loop
/// downloading  | author (late)    | ItemStarted not finished in the same batch
/// applied      | author           | ItemFinished ok (RemoteChangeDetected enriches, or creates when unwitnessed)
/// failed       | author (late)    | ItemFinished with an error
///
/// Same-batch collapse: ItemStarted + ItemFinished landing in ONE poll batch
/// (the normal case for small files) produce only the finished entry — one
/// fact, not two rows dated a millisecond apart.
///
/// ## Outbound synthesis (there are NO per-item upload events upstream)
///
/// The only per-file outbound signal is RemoteDownloadProgress: the set of
/// paths a remote reports actively fetching, ~5s cadence. The feed keeps the
/// last reported set per (device, folder) and DIFFS each new report:
/// appearances log sending entries (create-on-mention — any path the feed
/// hears about gets an entry, witnessed detect or not), disappearances mean
/// the transfer ended — completion is then confirmed, never assumed, by one
/// bounded `/rest/db/file` availability read. Boundaries, all upstream:
/// single-block files (< ~128 KiB) never appear in progress reports, and
/// sub-5s transfers fall between ticks — those confirm via remoteneed,
/// catch-up, or the sweep instead.
///
/// **Delivery to ≥1 device closes a loop** (decided 2026-08-17 after a full
/// case enumeration — do not reopen without new evidence): a Detected entry
/// is an UNSCOPED beginning ("this Mac changed X" names no replica), so it
/// is owed exactly one ending — "X made it off this machine". Per-replica
/// endings still log wherever per-replica beginnings were witnessed (a
/// sending→Ada entry gets its delivered→Ada from direct transfer evidence,
/// ledger or not), and per-replica POSITION is a state question that lives
/// in Syncthing's own UI (Open Syncthing) — state, not activity, is never
/// this window's job. The decisive argument against a full per-replica
/// ledger is the window's own ephemerality: an offline replica's "delivered"
/// ending could only land if the window happened to be open when that
/// device eventually returned — a contract the drop-on-close model cannot
/// keep.
///
/// ## The quiescence sweep (closing loops when the event was missed)
///
/// Event cues close loops within seconds. But cues can be missed — stream
/// reconnects, ring overflow, daemon restarts, sleep/wake — and a folder
/// that finished syncing goes silent, so a missed cue would dangle forever.
/// The sweep enforces principle 3: when open loops have gone stale
/// (`sweepAfter`), the stream's own wakes (including the ~50s empty
/// timeouts — no new timers) probe OUR OWN daemon's index: one tiny
/// `/rest/db/completion` read per stale folder × connected device — caught
/// up closes everything, partial progress falls back to one remoteneed page
/// for per-item closure. Throttled per folder (`sweepMinInterval`), skipped
/// for offline devices, zero cost while no loops are open. The event path
/// stays primary; a sweep that actually closes something logs the fact.
///
/// ## Lifecycle & frugality (unchanged contracts)
///
/// The window shows ACTIVITY WITNESSED WHILE OPEN — no seeding of any kind
/// (not history: delivery-blind; not the work queue: backlog is not
/// activity — standing state of any kind is Syncthing's own UI's job, via
/// Open Syncthing; the in-window Devices panel that once carried it was
/// removed 2026-08-18 as undiscoverable and duplicative). Closing drops
/// everything; every open starts EMPTY. The long-poll loop (`EventStream`)
/// runs ONLY while the window is visible and the session is connected;
/// closed window = zero cost. All confirmation queries are bounded and
/// gated — by events, or by stale open loops — never timer-driven, never
/// per-row; offline peers cost nothing.
@MainActor
final class ActivityFeed: ObservableObject {

    // MARK: - Entry

    struct Entry: Identifiable, Equatable {
        enum Operation: Equatable {
            case modified
            case deleted
        }

        /// What happened — the entry's verb. Direction is a property of the
        /// verb: detections and the transfer/delivery kinds are outbound
        /// facts (a local change heading out), the item events are inbound
        /// facts (a remote change landing here).
        enum Kind: Equatable {
            case detected           // a local change was observed
            case sending            // a remote started fetching the item
            case delivered          // confirmed: the remote has the item
            case downloading        // an inbound apply started (and outlived its batch)
            case applied            // an inbound change finished applying here
            case failed(String)     // an inbound apply failed (error text)

            var isOutbound: Bool {
                switch self {
                case .detected, .sending, .delivered: true
                case .downloading, .applied, .failed: false
                }
            }
        }

        let id = UUID()
        /// The daemon's event time. Never re-stamped.
        let time: Date
        let kind: Kind
        let folderID: String
        let folderLabel: String
        /// Folder-relative path; EMPTY for bulk entries (which summarize a
        /// count, not an item — and are therefore invisible to name search,
        /// a documented boundary of the aggregate tier).
        let path: String
        /// What happened to the file. Add vs modify is indistinguishable
        /// from the API (both sides report new files as modified/update);
        /// rename arrives as delete + add (two entries). Bulk entries mix
        /// operations and carry .modified (so the Deletes-only filter hides
        /// them — accepted). Enrichable for one reason only: a
        /// backstop-recovered entry guesses .modified (filenames carry no
        /// operation) and the real change event, arriving late, corrects it.
        var operation: Operation
        /// Machine-scale tier: the number of changes this BULK entry stands
        /// for. nil = an ordinary single-item entry.
        let bulkCount: Int?
        /// Display name of the entry's other party — the author ("This Mac"
        /// for local detections, the originating device for inbound entries;
        /// see principle 4) or, for sending/delivered, the recipient. The
        /// one enrichable field: inbound entries start nil (rendered "—")
        /// until the commit event identifies the author.
        var party: String?

        /// The Name column's text: the path, except bulk entries summarize
        /// their count.
        var displayName: String {
            guard let bulkCount else { return path }
            return bulkCount == 1 ? "1 change" : "\(bulkCount.formatted()) changes"
        }

        // MARK: Sort keys (display sorting reads these via KeyPathComparator)

        /// The Device column's display string — also its sort key, so the
        /// cell and the comparator share one definition.
        var partyDisplay: String {
            party ?? "—"
        }

        /// Attention order: ascending puts problems first — failed, then
        /// in-flight, then observations, then settled outcomes.
        var kindSortKey: Int {
            switch kind {
            case .failed: 0
            case .downloading: 1
            case .sending: 2
            case .detected: 3
            case .delivered: 4
            case .applied: 5
            }
        }
    }

    // MARK: - Published state & tuning

    /// Newest first. Bounded (`maxEntries`) — the window is a recent-activity
    /// readout, not a log archive.
    @Published private(set) var entries: [Entry] = []

    private static let maxEntries = 500
    /// The human/machine scale boundary, used two ways: a poll batch
    /// carrying MORE detections than this for one folder coalesces into one
    /// bulk entry instead of a wall of per-item rows (principle 5), and the
    /// index-update backstop aggregates (or, unnamed, suppresses) beyond it
    /// instead of recovering per-item. Generous on purpose — every
    /// coalesced item is invisible to name search.
    static let bulkDetectionThreshold = 25
    /// How long an open loop may wait for its event-driven ending before the
    /// quiescence sweep probes for it. Comfortably past the event cadence
    /// (completion ticks ~2s, progress reports ~5s).
    private static let sweepAfter: TimeInterval = 30
    /// Per-folder floor between sweep probes — during a long transfer the
    /// stream wakes every ~5s, and one probe per wake would break the
    /// "a few small reads per minute" cost promise.
    private static let sweepMinInterval: TimeInterval = 30

    /// All stored properties have defaults; nonisolated so the owner (a
    /// nonisolated app delegate) can create the feed at construction time.
    nonisolated init() {}

    /// Injectable seams (the monitor's established pattern): tests exercise
    /// the retry path and the sweep's staleness clock without real time.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    var now: () -> Date = Date.init

    // MARK: - Private state

    private var api: SyncthingAPI?
    private var windowVisible = false
    private var stream: EventStream<SyncthingAPI.ActivityEvent>?

    // Identity tables (refreshed at loop start and on ConfigSaved).
    /// Folder id → display label; the item events carry only the folder id.
    private var folderLabels: [String: String] = [:]
    /// Short device id (the 7-char prefix modifiedBy carries) → display name.
    private var deviceNames: [String: String] = [:]
    /// This device's id — FolderCompletion events for the local device (if
    /// the daemon ever emits them) are not a remote's position.
    private var myID: String?
    /// Full ids of currently connected remotes (seeded from
    /// /rest/system/connections; maintained by DeviceConnected/Disconnected).
    private var connectedIDs: Set<String> = []
    /// Folder id → the OTHER devices sharing it (from folder config) — the
    /// sweep's probe scope: only a sharer can answer for a folder, so
    /// nobody else is asked.
    private var folderSharers: [String: Set<String>] = [:]
    /// Folders whose local changes CAN be delivered: the folder sends (not
    /// receive-only) and at least one other device shares it. Loops open
    /// only here (principle 3's "where one is owed") — elsewhere a detected
    /// entry stands alone, true and promising nothing.
    private var deliverableFolders: Set<String> = []

    // Outbound synthesis state (see the class doc's outbound + sweep sections).
    /// The open loops awaiting their delivered ending.
    private var ledger = OutboundLedger()
    /// The last actively-downloading set each (device, folder) reported —
    /// the state-map diff baseline. Cleared at every loop (re)seed: a diff
    /// across a stream gap would fabricate transfers we never witnessed.
    private var reportedDownloads: [TransferKey: Set<String>] = [:]
    /// Transfers that ended (path disappeared from a device's state map),
    /// awaiting their one bounded availability read.
    private var pendingDeliveryChecks: [DeliveryCheck] = []
    /// Per-folder PATHS witnessed since that folder's last LocalIndexUpdated
    /// — the backstop's baseline, by name: index items we did not witness
    /// are recovered as named detections (small gaps) or a bulk entry (large
    /// ones). Bounded: cleared at every index event, which the daemon emits
    /// at least once per ~1000 items.
    private var witnessedSinceIndexUpdate: [String: Set<String>] = [:]
    /// Per-folder sweep throttle (`sweepMinInterval`).
    private var lastSweep: [String: Date] = [:]
    /// Paths whose detected entry came from backstop RECOVERY, awaiting the
    /// real change event: LocalChangeDetected consumes the marker instead of
    /// logging a duplicate (the daemon can emit LocalIndexUpdated BEFORE the
    /// change events it covers — observed live 2026-08-18 as doubled
    /// detected rows). Markers for a folder are cleared at its next index
    /// event, so a marker never outlives one index cycle and a genuinely
    /// new later change always logs.
    private var recoveredDetections: Set<ItemKey> = []

    private struct TransferKey: Hashable {
        let folder: String
        let device: String
    }

    private struct DeliveryCheck {
        let folder: String
        let path: String
        let device: String   // full id
        let time: Date       // the disappearance event's time
    }

    private struct ItemKey: Hashable {
        let folder: String
        let path: String
    }

    // MARK: - Session & window lifecycle

    /// Session fan-out, mirroring `SyncthingMonitor`: safe to call on every
    /// publish (restarts the loop against the fresh endpoint if active).
    func connect(api: SyncthingAPI) {
        self.api = api
        if windowVisible { startLoop() }
    }

    /// The daemon is gone; its event stream and subscriptions died with it.
    /// Entries stay — the log remains readable in the open window.
    func disconnect() {
        api = nil
        stopLoop()
    }

    /// The window controller's visibility signal — the feature's on/off
    /// switch. Closing DROPS the log and every open loop: the window is a
    /// "happening now" view, not an archive. Every open starts fresh.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        if visible {
            startLoop()
        } else {
            stopLoop()
            entries = []
            ledger.removeAll()
            reportedDownloads = [:]
            pendingDeliveryChecks = []
            witnessedSinceIndexUpdate = [:]
            recoveredDetections = []
            lastSweep = [:]
        }
    }

    // MARK: - The event loop

    /// No endpoint-suspect escalation on this stream — `SyncthingMonitor` is
    /// the session's health probe; if the daemon is really gone the session
    /// flips unavailable and disconnects us, so this stream retries forever.
    private func startLoop() {
        guard let api else { return }
        stopLoop()
        let stream = EventStream<SyncthingAPI.ActivityEvent>(
            label: "activity",
            fetch: { try await api.activityEvents(since: $0, timeout: $1, limit: $2) },
            seed: { [weak self] in
                guard let self else { return }
                try await self.refreshIdentity(api: api)
                // A (re)seed means the stream (re)started: per-tick state is
                // unknowable across the gap. Open LOOPS stay — the sweep and
                // the confirmation queries are computed against live truth,
                // so they remain sound (and the sweep is exactly what closes
                // loops whose confirming events fell into the gap).
                self.reportedDownloads = [:]
                self.witnessedSinceIndexUpdate = [:]
                self.recoveredDetections = []
                // Deliberately NO entry seeding — the window renders
                // witnessed activity only (see the class doc).
            },
            handle: { [weak self] events in
                await self?.handleBatch(events, api: api)
            })
        stream.retrySleep = retrySleep
        self.stream = stream
        stream.start()
    }

    private func stopLoop() {
        stream?.stop()
        stream = nil
    }

    /// Identity tables, read at loop start and re-read when ConfigSaved
    /// reports the configuration changed (folder labels, the device list,
    /// share lists, and folder types would otherwise go stale while the
    /// window is open).
    private func refreshIdentity(api: SyncthingAPI) async throws {
        let folders = try await api.folders()
        let devices = try await api.devices()
        let my = try await api.myID()
        myID = my
        folderLabels = Dictionary(uniqueKeysWithValues: folders
            .map { ($0.id, $0.label.isEmpty ? $0.id : $0.label) })
        deviceNames = Dictionary(uniqueKeysWithValues: devices.map {
            (String($0.deviceID.prefix(7)),
             ($0.name?.isEmpty ?? true) ? String($0.deviceID.prefix(7)) : $0.name!)
        })
        folderSharers = Dictionary(uniqueKeysWithValues: folders.map { folder in
            (folder.id, Set((folder.devices ?? []).map(\.deviceID)).subtracting([my]))
        })
        deliverableFolders = Set(folders.filter { folder in
            (folder.type ?? "sendreceive") != "receiveonly"
                && !(folderSharers[folder.id]?.isEmpty ?? true)
        }.map(\.id))
        connectedIDs = (try? await api.connectedDevices()) ?? []
    }

    // MARK: - Batch processing

    /// Everything one poll batch accumulates before it commits: the working
    /// copy of the log plus the batch-scoped context the individual event
    /// handlers need.
    private struct BatchContext {
        var entries: [Entry]
        /// Downloading entries created in THIS batch, so a finish arriving
        /// moments later collapses with its start (same-batch collapse).
        var startedThisBatch: [ItemKey: UUID] = [:]
        /// (folder, device) pairs whose FolderCompletion moved this batch —
        /// the remoteneed confirmation cue, deduped per batch.
        var deliveryTriggers: [TransferKey: Date] = [:]
        /// Folders whose detections this batch crossed `bulkDetectionThreshold`
        /// — their detections coalesce instead of logging per-item.
        var bulkFolders: Set<String> = []
        /// folder → coalesced detection count + a representative time; one
        /// bulk detected entry per folder is emitted after the event loop.
        var bulkDetected: [String: (count: Int, time: Date)] = [:]
        var sawConfigChange = false
    }

    /// One wake of the stream (`handle` runs on EVERY wake, including empty
    /// ~50s timeouts — which is what lets the sweep ride the wakes). The
    /// pipeline, in order:
    /// 1. scale partition — folders whose detections exceed the bulk threshold
    /// 2. per-event application (entries, ledger, triggers)
    /// 3. bulk detected entries for the coalesced folders
    /// 4. remoteneed confirmations for this batch's completion triggers
    /// 5. the quiescence sweep, if any open loop has gone stale
    /// 6. commit, then the fire-and-forget availability checks
    /// 7. housekeeping: identity refresh when ConfigSaved arrived
    private func handleBatch(_ events: [SyncthingAPI.ActivityEvent],
                             api: SyncthingAPI) async {
        var context = BatchContext(entries: entries)
        var detectionCounts: [String: Int] = [:]
        for event in events where event.type == "LocalChangeDetected" {
            if let folder = event.folder { detectionCounts[folder, default: 0] += 1 }
        }
        context.bulkFolders = Set(detectionCounts.filter {
            $0.value > Self.bulkDetectionThreshold
        }.keys)

        for event in events {
            apply(event, to: &context)
        }
        logBulkDetections(&context)
        await confirmDeliveries(context.deliveryTriggers, api: api,
                                entries: &context.entries)
        await sweepStaleLoops(api: api, entries: &context.entries)
        commit(context.entries)
        resolvePendingDeliveryChecks(api: api)

        if context.sawConfigChange {
            try? await refreshIdentity(api: api)
        }
    }

    /// Merge one event into the batch. See the kind table in the class doc —
    /// this function IS that table's evidence column.
    private func apply(_ event: SyncthingAPI.ActivityEvent, to context: inout BatchContext) {
        switch event.type {
        case "ConfigSaved":
            context.sawConfigChange = true
            return
        case "FolderCompletion":
            applyFolderCompletion(event, to: &context)
            return
        case "RemoteDownloadProgress":
            applyTransferReport(event, to: &context)
            return
        case "LocalIndexUpdated":
            applyIndexUpdateBackstop(event, to: &context)
            return
        case "DeviceConnected":
            // Connectivity gates the sweep (only connected sharers are
            // probed) — maintained even with no UI consuming it directly.
            if let device = event.device { connectedIDs.insert(device) }
            return
        case "DeviceDisconnected":
            if let device = event.device { connectedIDs.remove(device) }
            return
        default:
            break
        }

        guard let folder = event.folder, let path = event.path else { return }
        let label = event.label ?? folderLabel(for: folder)
        let key = ItemKey(folder: folder, path: path)
        let isDelete = event.action == "delete" || event.action == "deleted"
        let operation: Entry.Operation = isDelete ? .deleted : .modified

        switch event.type {
        case "LocalChangeDetected":
            witnessedSinceIndexUpdate[folder, default: []].insert(path)
            // The backstop already logged this change (recovery from an
            // index event that arrived first): consume the marker — the
            // entry exists, a second would be a duplicate of the same fact.
            // But the recovery GUESSED .modified, and this event knows the
            // truth — correct the entry and the open loop, or a real delete
            // renders as a modify all the way through delivery (regressed
            // and caught live 2026-08-18).
            if recoveredDetections.remove(key) != nil {
                if operation == .deleted {
                    if let index = context.entries.firstIndex(where: {
                        $0.kind == .detected && $0.folderID == folder && $0.path == path
                    }) {
                        context.entries[index].operation = .deleted
                    }
                    if deliverableFolders.contains(folder) {
                        ledger.track(folder: folder, path: path, operation: .deleted,
                                     at: now())
                    }
                }
                return
            }
            if context.bulkFolders.contains(folder) {
                // Machine scale: coalesce (logBulkDetections emits the entry).
                var bulk = context.bulkDetected[folder] ?? (count: 0, time: event.time)
                bulk.count += 1
                bulk.time = event.time
                context.bulkDetected[folder] = bulk
            } else {
                context.entries.insert(Entry(time: event.time, kind: .detected,
                                             folderID: folder, folderLabel: label,
                                             path: path, operation: operation,
                                             bulkCount: nil, party: "This Mac"), at: 0)
                // A loop opens only where delivery is possible in principle
                // (principle 3): on a receive-only or unshared folder the
                // detected entry stands alone — opening a loop there would
                // synthesize a false "delivered" the moment a remote reads
                // completion 100.
                if deliverableFolders.contains(folder) {
                    ledger.track(folder: folder, path: path, operation: operation,
                                 at: now())
                }
            }

        case "ItemStarted":
            let entry = Entry(time: event.time, kind: .downloading, folderID: folder,
                              folderLabel: label, path: path, operation: operation,
                              bulkCount: nil, party: nil)
            context.entries.insert(entry, at: 0)
            context.startedThisBatch[key] = entry.id

        case "ItemFinished":
            // Applied items advance the local index too — witnessing them by
            // name keeps them out of the backstop's unwitnessed set.
            witnessedSinceIndexUpdate[folder, default: []].insert(path)
            let kind: Entry.Kind = event.error.map { .failed($0) } ?? .applied
            // Same-batch collapse: replace the start logged moments ago
            // rather than keeping both halves of one sub-batch fact.
            if let startID = context.startedThisBatch.removeValue(forKey: key) {
                context.entries.removeAll { $0.id == startID }
            }
            context.entries.insert(Entry(time: event.time, kind: kind, folderID: folder,
                                         folderLabel: label, path: path,
                                         operation: operation, bulkCount: nil,
                                         party: nil), at: 0)

        case "RemoteChangeDetected":
            let author = event.modifiedBy.map { deviceNames[$0] ?? $0 }
            // The commit event names the author — enrich the applied entry
            // still awaiting one (metadata enrichment, never a state change).
            if let index = context.entries.firstIndex(where: {
                $0.kind == .applied && $0.folderID == folder && $0.path == path
                    && $0.party == nil
            }) {
                context.entries[index].party = author
            } else {
                // A commit with no witnessed apply (e.g. subscription started
                // mid-apply): still a real, settled inbound change.
                context.entries.insert(Entry(time: event.time, kind: .applied,
                                             folderID: folder, folderLabel: label,
                                             path: path, operation: operation,
                                             bulkCount: nil, party: author), at: 0)
            }

        default:
            break
        }
    }

    // MARK: - Outbound: transfer reports (per-item evidence)

    /// RemoteDownloadProgress: diff the device's reported set against its
    /// previous report. Appearances log sending entries (create-on-mention —
    /// any path the feed hears about gets an entry, witnessed detect or
    /// not); disappearances mean the transfer ended and queue the one
    /// bounded availability read that decides whether "delivered" is true.
    /// An empty report (the relay of the remote's final empty
    /// DownloadProgress message) is a full disappearance.
    private func applyTransferReport(_ event: SyncthingAPI.ActivityEvent,
                                     to context: inout BatchContext) {
        guard let folder = event.folder, let device = event.device, device != myID
        else { return }
        let reported = Set(event.downloadingPaths ?? [])
        let key = TransferKey(folder: folder, device: device)
        let previous = reportedDownloads[key] ?? []
        reportedDownloads[key] = reported

        let party = displayName(forFullID: device)
        let label = folderLabel(for: folder)
        // Sorted (then reversed, since each insert lands on top) so a burst
        // of appearances logs in deterministic path order.
        for path in reported.subtracting(previous).sorted().reversed() {
            context.entries.insert(Entry(time: event.time, kind: .sending,
                                         folderID: folder, folderLabel: label,
                                         path: path, operation: .modified,
                                         bulkCount: nil, party: party), at: 0)
            ledger.track(folder: folder, path: path, operation: .modified, at: now())
        }
        for path in previous.subtracting(reported) {
            pendingDeliveryChecks.append(DeliveryCheck(folder: folder, path: path,
                                                       device: device, time: event.time))
        }
    }

    // MARK: - Outbound: folder completion (catch-up + confirmation cues)

    private func applyFolderCompletion(_ event: SyncthingAPI.ActivityEvent,
                                       to context: inout BatchContext) {
        guard let folder = event.folder, let device = event.device, device != myID
        else { return }
        if isFullCatchUp(event) {
            // The device needs NOTHING: every open loop in the folder is
            // confirmed — per-item loops individually (the person at the
            // console needs WHICH items completed, not "caught up"), the
            // bulk loop as one bulk delivered entry. needDeletes must be
            // zero too: a deletes-only backlog can report completion 100
            // with tombstones still undelivered.
            if let closure = ledger.closeFolder(folder) {
                logClosure(closure, folder: folder,
                           party: displayName(forFullID: device),
                           time: event.time, into: &context.entries)
                Log.monitor.log("activity catch-up: \(closure.items.count) items + \(closure.bulkCount) bulk confirmed by \(device.prefix(7), privacy: .public)")
            }
        } else {
            // Partial progress: cue for one bounded remoteneed read.
            context.deliveryTriggers[TransferKey(folder: folder, device: device)]
                = event.time
        }
    }

    private func isFullCatchUp(_ event: SyncthingAPI.ActivityEvent) -> Bool {
        event.completion == 100 && event.needItems == 0 && (event.needDeletes ?? 0) == 0
    }

    // MARK: - Outbound: the bulk tier (machine-scale evidence)

    /// LocalIndexUpdated is the burst backstop: one BATCHED event per ~1000
    /// index items, so it survives the ring overflow that eats per-file
    /// events during machine-scale churn. Items it reports that we did not
    /// witness are changes we never saw — and the comparison is BY NAME
    /// against the witnessed-path set, because the event carries the batch's
    /// `filenames`:
    /// - filenames complete (count == items): unwitnessed names become real
    ///   per-item detected entries — a missed change gets its NAME, not a
    ///   "1 change" row — unless there are more than the bulk threshold, in
    ///   which case the same scale rule as burst batches applies (one bulk
    ///   entry).
    /// - filenames truncated or absent: only the count is trustworthy, and
    ///   only at scale — a numeric surplus above the threshold logs a bulk
    ///   entry; a small unnamed surplus is SUPPRESSED (indistinguishable
    ///   from bookkeeping slop — index batches cover things no per-file
    ///   event we consume describes — and principle 2 degrades by omission,
    ///   never by a vague claim). This suppression is what killed the
    ///   spurious "1 change" rows seen live 2026-08-17.
    /// Recovered entries default to .modified: the filenames say nothing
    /// about the operation (a recovered tombstone renders as a modify —
    /// accepted).
    private func applyIndexUpdateBackstop(_ event: SyncthingAPI.ActivityEvent,
                                          to context: inout BatchContext) {
        guard let folder = event.folder, let items = event.items else { return }
        let witnessed = witnessedSinceIndexUpdate.removeValue(forKey: folder) ?? []
        // A new index cycle: change events covered by the PREVIOUS cycle
        // have long since arrived, so unconsumed recovery markers are
        // genuinely-lost events — retire them (their entries stand).
        recoveredDetections = recoveredDetections.filter { $0.folder != folder }

        if let filenames = event.filenames, filenames.count == items {
            let unwitnessed = filenames.filter { !witnessed.contains($0) }
            guard !unwitnessed.isEmpty else { return }
            if unwitnessed.count > Self.bulkDetectionThreshold {
                addBulkDetections(count: unwitnessed.count, folder: folder,
                                  time: event.time, to: &context)
            } else {
                recoverDetections(unwitnessed, folder: folder, time: event.time,
                                  to: &context)
            }
            Log.monitor.log("activity backstop: \(unwitnessed.count) unwitnessed changes recovered by name")
        } else {
            let surplus = items - witnessed.count
            guard surplus > 0 else { return }
            guard surplus > Self.bulkDetectionThreshold else {
                Log.monitor.log("activity backstop: \(surplus) unnamed surplus items suppressed")
                return
            }
            addBulkDetections(count: surplus, folder: folder, time: event.time,
                              to: &context)
            Log.monitor.log("activity backstop: \(surplus) unwitnessed changes recorded in bulk")
        }
    }

    private func addBulkDetections(count: Int, folder: String, time: Date,
                                   to context: inout BatchContext) {
        var bulk = context.bulkDetected[folder] ?? (count: 0, time: time)
        bulk.count += count
        bulk.time = time
        context.bulkDetected[folder] = bulk
    }

    /// Log per-item detected entries for names the backstop recovered.
    /// Duplicate protection runs BOTH ways, because the daemon's emission
    /// order isn't guaranteed: a path whose newest entry is already a
    /// detected is skipped (change event arrived first), and every recovered
    /// path leaves a marker that a late-arriving change event consumes
    /// instead of logging again (index event arrived first).
    private func recoverDetections(_ paths: [String], folder: String, time: Date,
                                   to context: inout BatchContext) {
        let label = folderLabel(for: folder)
        for path in paths.sorted().reversed() {
            if let newest = context.entries.first(where: {
                $0.folderID == folder && $0.path == path
            }), newest.kind == .detected { continue }
            context.entries.insert(Entry(time: time, kind: .detected, folderID: folder,
                                         folderLabel: label, path: path,
                                         operation: .modified, bulkCount: nil,
                                         party: "This Mac"), at: 0)
            recoveredDetections.insert(ItemKey(folder: folder, path: path))
            if deliverableFolders.contains(folder) {
                ledger.track(folder: folder, path: path, operation: .modified, at: now())
            }
        }
    }

    /// Emit one bulk detected entry per coalesced folder (threshold bursts +
    /// backstop surpluses accumulated by this batch) and open the matching
    /// bulk loop — subject to the same delivery-expectation gate as
    /// per-item loops.
    private func logBulkDetections(_ context: inout BatchContext) {
        for (folder, bulk) in context.bulkDetected.sorted(by: { $0.key < $1.key })
        where bulk.count > 0 {
            context.entries.insert(Entry(time: bulk.time, kind: .detected,
                                         folderID: folder,
                                         folderLabel: folderLabel(for: folder),
                                         path: "", operation: .modified,
                                         bulkCount: bulk.count, party: "This Mac"),
                                   at: 0)
            if deliverableFolders.contains(folder) {
                ledger.addBulk(folder: folder, count: bulk.count, at: now())
            }
        }
    }

    // MARK: - Closing loops

    /// Per-item delivery confirmation: for each triggering (folder, device),
    /// one bounded remoteneed query — tracked paths ABSENT from the complete
    /// need list were delivered to that device. Skips folders with nothing
    /// tracked; skips silently on query failure or a truncated list (loops
    /// stay open for the catch-up or the sweep — lag, never lie).
    private func confirmDeliveries(_ triggers: [TransferKey: Date],
                                   api: SyncthingAPI, entries: inout [Entry]) async {
        for (key, time) in triggers {
            guard ledger.hasTrackedItems(in: key.folder) else { continue }
            guard let need = try? await api.remoteNeed(folder: key.folder,
                                                       device: key.device),
                  need.complete else { continue }
            let closed = ledger.closeItems(in: key.folder, absentFrom: need.needed)
            guard !closed.isEmpty else { continue }
            let party = displayName(forFullID: key.device)
            for (path, item) in closed.reversed() {
                insertDelivered(folder: key.folder, path: path,
                                operation: item.operation, party: party,
                                time: time, into: &entries)
            }
            Log.monitor.log("activity remoteneed: \(closed.count) deliveries confirmed by \(key.device.prefix(7), privacy: .public)")
        }
    }

    /// The quiescence sweep (see the class doc): close loops whose
    /// event-driven ending never arrived. Probes our own daemon's index —
    /// one completion read per stale folder × connected device; a caught-up
    /// device closes everything, partial progress falls back to remoteneed
    /// for per-item closure. Runs on the wakes the stream already makes;
    /// costs nothing while no loops are open or none is stale.
    private func sweepStaleLoops(api: SyncthingAPI, entries: inout [Entry]) async {
        let staleFolders = ledger.folders(
            withLoopsOlderThan: now().addingTimeInterval(-Self.sweepAfter))
        guard !staleFolders.isEmpty else { return }

        for folder in staleFolders {
            // Only a CONNECTED SHARER of this folder can answer for it —
            // nobody else is probed. No connected sharer (offline peers,
            // config changed under us) = the loop waits at zero cost.
            let sharers = folderSharers[folder, default: []].intersection(connectedIDs)
            guard !sharers.isEmpty else { continue }
            if let last = lastSweep[folder],
               now().timeIntervalSince(last) < Self.sweepMinInterval { continue }
            lastSweep[folder] = now()
            for device in sharers.sorted() {
                // 404 = paused/unaccepted on their side — skip.
                guard let completion = try? await api.completion(folder: folder,
                                                                 device: device)
                else { continue }
                if completion.needItems == 0 && completion.needDeletes == 0 {
                    if let closure = ledger.closeFolder(folder) {
                        logClosure(closure, folder: folder,
                                   party: displayName(forFullID: device),
                                   time: now(), into: &entries)
                        Log.monitor.log("activity sweep: closed \(closure.items.count) items + \(closure.bulkCount) bulk — \(device.prefix(7), privacy: .public) caught up")
                    }
                    break   // folder fully closed; no more probing needed
                } else if ledger.hasTrackedItems(in: folder),
                          let need = try? await api.remoteNeed(folder: folder,
                                                               device: device),
                          need.complete {
                    let closed = ledger.closeItems(in: folder,
                                                   absentFrom: need.needed)
                    guard !closed.isEmpty else { continue }
                    let party = displayName(forFullID: device)
                    for (path, item) in closed.reversed() {
                        insertDelivered(folder: folder, path: path,
                                        operation: item.operation, party: party,
                                        time: now(), into: &entries)
                    }
                    Log.monitor.log("activity sweep: \(closed.count) deliveries confirmed by \(device.prefix(7), privacy: .public)")
                }
            }
        }
    }

    /// Resolve queued transfer-end checks: one `/rest/db/file` read each,
    /// fire-and-forget — our own index says whether the device now has the
    /// file. Confirmed → a delivered entry; unconfirmed (failed transfer,
    /// re-queued, lookup failure) → nothing, honestly. Bounded by the
    /// mention rate; costs nothing while no transfers end.
    private func resolvePendingDeliveryChecks(api: SyncthingAPI) {
        let pending = pendingDeliveryChecks
        pendingDeliveryChecks.removeAll()
        for check in pending {
            Task { @MainActor in
                guard let status = try? await api.fileStatus(folder: check.folder,
                                                             file: check.path),
                      status.availableOn.contains(check.device),
                      self.windowVisible else { return }
                let operation = self.ledger.closeItem(folder: check.folder,
                                                      path: check.path)?.operation
                    ?? .modified
                var updated = self.entries
                self.insertDelivered(folder: check.folder, path: check.path,
                                     operation: operation,
                                     party: self.displayName(forFullID: check.device),
                                     time: check.time, into: &updated)
                self.commit(updated)
            }
        }
    }

    /// Convert one folder closure into log entries: per-item delivered
    /// entries for the loops we tracked by name, one bulk delivered entry
    /// for the count-only loop — endings at the same granularity as their
    /// beginnings (principle 5).
    private func logClosure(_ closure: OutboundLedger.FolderClosure, folder: String,
                            party: String, time: Date, into entries: inout [Entry]) {
        for (path, item) in closure.items.reversed() {
            insertDelivered(folder: folder, path: path, operation: item.operation,
                            party: party, time: time, into: &entries)
        }
        if closure.bulkCount > 0 {
            entries.insert(Entry(time: time, kind: .delivered, folderID: folder,
                                 folderLabel: folderLabel(for: folder), path: "",
                                 operation: .modified, bulkCount: closure.bulkCount,
                                 party: party), at: 0)
        }
    }

    /// One delivered entry per (path, device) fact PER EPISODE. The
    /// confirmation paths overlap by design (remoteneed, the availability
    /// check, catch-up, and the sweep can each prove the same delivery), so
    /// a delivery is suppressed only when a delivered entry for this
    /// (path, device) is already NEWER than the path's latest
    /// detected/sending entry — this episode is already confirmed. An OLDER
    /// delivered entry belongs to a previous episode of a re-changed path
    /// and must not swallow the new fact (session-wide dedupe silently ate
    /// every re-churned file's delivery after its first — the Photos bug,
    /// diagnosed from live logs 2026-08-17).
    ///
    /// The array is newest-first, so `firstIndex` finds the newest match and
    /// a LOWER index means newer. A delivered match with NO episode start in
    /// the log also suppresses: eviction trims oldest-first, so a surviving
    /// delivered entry outlived an older start — it can only belong to the
    /// current episode.
    private func insertDelivered(folder: String, path: String,
                                 operation: Entry.Operation, party: String,
                                 time: Date, into entries: inout [Entry]) {
        if let deliveredIndex = entries.firstIndex(where: {
            $0.kind == .delivered && $0.folderID == folder && $0.path == path
                && $0.party == party
        }) {
            let episodeStart = entries.firstIndex {
                ($0.kind == .detected || $0.kind == .sending)
                    && $0.folderID == folder && $0.path == path
            }
            guard let episodeStart, deliveredIndex > episodeStart else { return }
        }
        entries.insert(Entry(time: time, kind: .delivered, folderID: folder,
                             folderLabel: folderLabel(for: folder), path: path,
                             operation: operation, bulkCount: nil, party: party), at: 0)
    }

    /// Bounded append-only cap: newest first, so trimming the tail IS
    /// oldest-first eviction — the log's only rule.
    private func commit(_ updated: [Entry]) {
        var capped = updated
        if capped.count > Self.maxEntries {
            capped.removeLast(capped.count - Self.maxEntries)
        }
        if capped != entries { entries = capped }
    }

    // MARK: - Naming helpers

    private func folderLabel(for folder: String) -> String {
        folderLabels[folder] ?? folder
    }

    private func displayName(forFullID id: String) -> String {
        let short = String(id.prefix(7))
        return deviceNames[short] ?? short
    }
}
