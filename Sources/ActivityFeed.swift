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
/// ## Daemon events (the third row family, added 2026-09-04)
///
/// Beyond file facts and recording markers, the log records what happened
/// to FOLDERS and DEVICES, from the daemon's own events, under one
/// selection test: would someone reading the log later want to know it
/// happened, and when? Live state stays the menu's job. Recorded: device
/// and folder pause/resume (a same-batch burst — our own Pause All verb —
/// coalesces to "N devices"), peers going online/offline, a folder
/// entering `error` (one bounded `db/status` read fetches the text the
/// event lacks), and the filesystem watcher failing or recovering.
///
/// Folder SCANS are deliberately not recorded (settled 2026-09-04 after
/// two builds): the wanted rows were the SCHEDULED rescans, as a start and
/// an end with the duration, and never the watcher's subpath scans that
/// follow every change batch — but StateChanged is the only scan signal
/// and it is identical for a scheduled rescan, a watcher scan, and Rescan
/// All (folder, from, to, duration; no cause anywhere in the events or
/// REST). Timing against the rescan interval fails (Syncthing jitters the
/// schedule and watcher scans land anywhere), "scans that found changes"
/// fails both ways, FolderScanProgress measures bytes hashed. The one
/// accurate case — folders with the watcher disabled — is too odd an
/// ergonomics to ship. Rows we can't vouch for don't belong in the log. Evaluated and skipped, with
/// reasons, in `.claude/notes` (progress streams, FolderErrors' retry
/// re-emission, startup events unobservable by a fresh subscription,
/// network/protocol internals). These rows are gated by the display's own
/// "folder & device events" switch and hidden under a name search.
///
/// ## Lifecycle & frugality
///
/// The log holds ACTIVITY WITNESSED WHILE RECORDING — no seeding of any
/// kind (not history: delivery-blind; not the work queue: backlog is not
/// activity — standing state of any kind is Syncthing's own UI's job, via
/// Open Syncthing; the in-window Devices panel that once carried it was
/// removed 2026-08-18 as undiscoverable and duplicative). Recording runs
/// while it is WANTED — the policy says always, or the window is open — AND
/// POSSIBLE — the session has a live endpoint; the long-poll loop
/// (`EventStream`) exists exactly then, so under the default policy a
/// closed window is zero cost. Entries survive everything short of an
/// explicit clear; what a stop drops depends on WHY it stopped:
///
/// - **Pause** (recording no longer wanted): the daemon keeps syncing while
///   nobody watches, so every open loop is stale by construction — a loop
///   kept across a pause would later stamp an hours-old delivery with the
///   probe time (lag turned lie), pair a delivery with a detection of a
///   different change, or report a since-deleted file delivered. The
///   ledger and every per-tick structure are FLUSHED; the log keeps its
///   rows. Resuming is a fresh open against retained rows: a transfer that
///   spans the pause reappears as a new sending entry (create-on-mention)
///   and earns its delivered from real evidence.
/// - **Disconnect** (endpoint gone): the daemon is down, nothing was
///   delivered in the gap, the loops are genuinely still open — the
///   ledger is KEPT and their endings arrive from real events after the
///   reconnect (the reseed clears only the per-tick state).
///
/// All confirmation queries are bounded and gated — by events, or by stale
/// open loops — never timer-driven, never per-row; offline peers cost
/// nothing.
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

            // The log's OWN lifecycle — markers, not sync facts: where the
            // record is discontinuous. Started/paused follow flips of
            // "recording wanted" (window or policy), unconditionally;
            // connected/disconnected follow flips of the endpoint, only
            // while recording is wanted (a paused period hides everything,
            // daemon restarts included). Launch counts as a transition, so
            // every log begins with a started marker. Emitted on FLIPS only
            // — the inputs re-announce unchanged states — and never paired:
            // a connected may follow a started with no disconnected between
            // (window reopened during an outage, then the daemon returns);
            // that is the truth. Cap eviction can orphan a marker — accepted.
            case recordingStarted(MarkerReason)
            case recordingPaused(MarkerReason)
            case connected
            case disconnected

            // DAEMON EVENTS — the third family: things that happened to a
            // folder or device (not to a file), witnessed from the daemon's
            // own events. The selection test (2026-09-04): an event earns a
            // row if someone reading the log LATER would want to know it
            // happened, and when — live state is the menu's job, the log's
            // value is history. The subject rides the Folder or Device
            // column; the Name column carries the statement where there is
            // one (an error text, a scan duration), else stays blank.
            case devicePaused              // party = device (or "N devices")
            case deviceResumed
            case folderPaused              // folder = the folder (or "N folders")
            case folderResumed
            case deviceOnline              // a peer connected to us
            case deviceOffline
            case folderError(String)       // folder entered `error`; the text
            case watchFailed(String)       // the fs watcher stopped; the text
            case watchRestored

            var isMarker: Bool {
                switch self {
                case .recordingStarted, .recordingPaused, .connected, .disconnected: true
                default: false
                }
            }

            var isDaemonEvent: Bool {
                switch self {
                case .devicePaused, .deviceResumed, .folderPaused, .folderResumed,
                     .deviceOnline, .deviceOffline, .folderError,
                     .watchFailed, .watchRestored: true
                default: false
                }
            }

            /// Direction of a sync fact. Markers and daemon events are
            /// neither (the filter admits or excludes them before asking).
            var isOutbound: Bool {
                switch self {
                case .detected, .sending, .delivered: true
                default: false
                }
            }

            /// The Name column text for the non-file families — nil for a
            /// file fact (whose name is its path), empty for a daemon event
            /// whose subject lives entirely in the Folder/Device column.
            /// (Provisional copy, pending the visual-language pass.)
            var statement: String? {
                switch self {
                case .recordingStarted(.windowOpened): "Activity window opened"
                case .recordingStarted(.policySetToAlways): "Recording set to always"
                case .recordingPaused(.windowClosed): "Activity window closed"
                case .recordingPaused(.policySetToWhileWindowOpen):
                    "Recording set to while the window is open"
                case .recordingStarted, .recordingPaused: nil   // unreachable pairings
                case .connected: "Syncthing connected"
                case .disconnected: "Syncthing disconnected"
                case .devicePaused, .deviceResumed, .folderPaused, .folderResumed,
                     .deviceOnline, .deviceOffline, .watchRestored: ""
                case let .folderError(text), let .watchFailed(text): text
                default: nil
                }
            }
        }

        /// Which input flipped "recording wanted" — the marker's reason.
        enum MarkerReason: Equatable {
            case windowOpened
            case windowClosed
            case policySetToAlways
            case policySetToWhileWindowOpen
        }

        /// A marker entry: no folder, path, or party — only the kind and
        /// the wall-clock time of the transition.
        static func marker(_ kind: Kind, time: Date) -> Entry {
            Entry(time: time, kind: kind, folderID: "", folderLabel: "", path: "",
                  operation: .modified, bulkCount: nil, party: nil)
        }

        /// A daemon-event entry: the subject in the Folder and/or Device
        /// column, no path. `bulkCount` marks a coalesced burst ("3
        /// devices") the way it marks bulk file entries.
        static func daemonEvent(_ kind: Kind, time: Date, folderID: String = "",
                                folderLabel: String = "", party: String? = nil,
                                bulkCount: Int? = nil) -> Entry {
            Entry(time: time, kind: kind, folderID: folderID, folderLabel: folderLabel,
                  path: "", operation: .modified, bulkCount: bulkCount, party: party)
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
            if let statement = kind.statement { return statement }
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
            case .folderError, .watchFailed: 6
            case .devicePaused, .deviceResumed, .folderPaused, .folderResumed,
                 .deviceOnline, .deviceOffline, .watchRestored: 7
            case .recordingStarted, .recordingPaused, .connected, .disconnected: 8
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
    /// Transfer-end availability reads resolved per wake. A burst of ends
    /// (the final empty progress report after a big batch) would otherwise
    /// fan out into hundreds of concurrent `db/file` reads against the
    /// worker doing the sync. The rest wait for the next wake — ~5s during
    /// a transfer, ≤50s idle — and the quiescence sweep confirms any that
    /// go stale before their turn.
    private static let deliveryCheckBudget = 20

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
    private(set) var recordingPolicy: ActivityRecordingPolicy = .whileWindowOpen
    /// Whether recording is WANTED (policy or window), independent of the
    /// endpoint. Stored so a flip can be told from a repeat — the window
    /// controller and the session both re-announce unchanged states — and
    /// a flip to off is what flushes the open loops (a pause).
    private var isDesired = false
    private var stream: EventStream<SyncthingAPI.ActivityEvent>?
    /// Bumped whenever the log is replaced from outside the batch pipeline
    /// (loop start/stop, clear). A batch parks on network awaits mid-way and
    /// commits a snapshot taken at its start; it commits only if the epoch
    /// it started under is still current, so a pause or clear landing while
    /// a batch is parked is never overwritten by that batch. The same guard
    /// retires the fire-and-forget delivery checks of a stopped loop.
    private var logEpoch = 0

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
    /// The bulk-tier twin of `recoveredDetections`: when the backstop
    /// recovers a folder's changes IN BULK (index event first, at scale),
    /// the change events that follow are the same changes — each consumes
    /// one from this budget instead of logging, or the burst would
    /// coalesce into a second identical "N changes" row (seen live
    /// 2026-09-04). Retired at the folder's next index cycle, like the
    /// per-item markers.
    private var recoveredBulkBudget: [String: Int] = [:]

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

    // MARK: - Recording lifecycle

    /// Recording runs iff it is wanted (`isDesired`: the policy says always,
    /// or the window is open) AND possible (a live endpoint). The three
    /// inputs below each store their value and `reconcile()`; nothing else
    /// starts or stops the loop. See the class doc for what a pause drops
    /// versus what a disconnect keeps.

    /// Session fan-out, mirroring `SyncthingMonitor`: safe to call on every
    /// publish (restarts the loop against the fresh endpoint if recording).
    /// The connected marker keys off the nil→endpoint FLIP only — blip
    /// recoveries republish the same endpoint.
    func connect(api: SyncthingAPI) {
        let wasConnected = self.api != nil
        self.api = api
        if !wasConnected, isDesired { appendMarker(.connected) }
        syncLoop(restarting: true)
    }

    /// The daemon is gone; its event stream and subscriptions died with it.
    /// Entries AND open loops stay (nothing syncs while the daemon is down).
    func disconnect() {
        if api != nil, isDesired { appendMarker(.disconnected) }
        api = nil
        syncLoop()
    }

    /// The window controller's visibility signal.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        reconcileDesired(started: .windowOpened, paused: .windowClosed)
    }

    /// The user's policy (Settings). At launch the delegate applies the
    /// persisted policy before the session connects, so `always` begins the
    /// log with a started marker, then connected — launch is a transition.
    func setRecordingPolicy(_ policy: ActivityRecordingPolicy) {
        recordingPolicy = policy
        reconcileDesired(started: .policySetToAlways, paused: .policySetToWhileWindowOpen)
    }

    /// Re-derive "recording wanted" after a window or policy input changed;
    /// a flip logs its marker (with the reason the caller supplies — the
    /// input that moved) and, going off, pauses. Then align the loop.
    private func reconcileDesired(started: Entry.MarkerReason,
                                  paused: Entry.MarkerReason) {
        let desired = recordingPolicy == .always || windowVisible
        if desired != isDesired {
            isDesired = desired
            if desired {
                appendMarker(.recordingStarted(started))
            } else {
                appendMarker(.recordingPaused(paused))
                pause()
            }
        }
        syncLoop()
    }

    /// The loop exists iff recording is wanted AND possible.
    private func syncLoop(restarting: Bool = false) {
        if isDesired, api != nil {
            if stream == nil || restarting { startLoop() }
        } else {
            stopLoop()
        }
    }

    /// Markers land outside the batch pipeline, so they advance the epoch:
    /// a batch parked mid-await must not commit over them.
    private func appendMarker(_ kind: Entry.Kind) {
        logEpoch += 1
        commit([Entry.marker(kind, time: now())] + entries)
    }

    /// The user's Clear: empty the log and flush the open loops (a cleared
    /// log must not later receive a delivered whose detected the user
    /// removed). No marker — an empty log explains itself. Recording, if
    /// running, continues: only the batch parked right now, if any, is
    /// dropped (epoch).
    func clear() {
        logEpoch += 1
        entries = []
        flushOpenLoops()
    }

    /// Recording is no longer wanted: drop every open loop and per-tick
    /// structure (all stale the moment nobody watches — class doc), keep
    /// the rows.
    private func pause() {
        stopLoop()
        flushOpenLoops()
    }

    private func flushOpenLoops() {
        ledger.removeAll()
        pendingDeliveryChecks = []
        reportedDownloads = [:]
        witnessedSinceIndexUpdate = [:]
        recoveredDetections = []
        recoveredBulkBudget = [:]
        lastSweep = [:]
    }

    // MARK: - The event loop

    /// No endpoint-suspect escalation on this stream — `SyncthingMonitor` is
    /// the session's health probe; if the daemon is really gone the session
    /// flips unavailable and disconnects us, so this stream retries forever.
    private func startLoop() {
        guard let api else { return }
        stopLoop()
        logEpoch += 1
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
                self.recoveredBulkBudget = [:]
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
        guard stream != nil else { return }
        stream?.stop()
        stream = nil
        logEpoch += 1   // an in-flight batch of the stopped loop must not commit
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
        /// Pause/resume events this batch, by kind — a burst (Pause All)
        /// coalesces to one "N devices" / "N folders" row.
        var stateChanges: [StateChangeKind: Coalesced] = [:]
        /// Folders that entered `error` this batch: one bounded status
        /// read each, after the loop, for the error text.
        var errorFolders: [(folder: String, time: Date)] = []
    }

    enum StateChangeKind: Hashable {
        case devicePaused, deviceResumed, folderPaused, folderResumed
    }

    struct Coalesced {
        /// Display names (device names or folder labels), in event order.
        var names: [String] = []
        /// The folder ids, for folder kinds (device kinds leave it empty).
        var folderIDs: [String] = []
        var time: Date
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
        let epoch = logEpoch
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
        logStateChanges(&context)
        await logFolderErrors(&context, api: api)
        await confirmDeliveries(context.deliveryTriggers, api: api,
                                entries: &context.entries)
        await sweepStaleLoops(api: api, entries: &context.entries)
        // The awaits above parked this batch; if the log was replaced
        // underneath (pause, clear, loop restart) its snapshot is stale —
        // drop it rather than overwrite what happened meanwhile.
        guard logEpoch == epoch else { return }
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
            // probed) — and a peer coming online is a daemon-event row.
            // The daemon emits DeviceConnected per CONNECTION (a relay→direct
            // upgrade or a second connection fires it again with no
            // disconnect between — seen live 2026-09-04 as tripled Online
            // rows), so the row follows the device-level FLIP of our set.
            guard let device = event.device, device != myID else { return }
            guard connectedIDs.insert(device).inserted else { return }
            context.entries.insert(Entry.daemonEvent(.deviceOnline, time: event.time,
                                                     party: displayName(forFullID: device)),
                                   at: 0)
            return
        case "DeviceDisconnected":
            guard let device = event.device, device != myID else { return }
            guard connectedIDs.remove(device) != nil else { return }
            context.entries.insert(Entry.daemonEvent(.deviceOffline, time: event.time,
                                                     party: displayName(forFullID: device)),
                                   at: 0)
            return
        case "DevicePaused", "DeviceResumed":
            guard let device = event.device, device != myID else { return }
            let kind: StateChangeKind = event.type == "DevicePaused" ? .devicePaused
                                                                      : .deviceResumed
            var group = context.stateChanges[kind] ?? Coalesced(time: event.time)
            group.names.append(displayName(forFullID: device))
            group.time = event.time
            context.stateChanges[kind] = group
            return
        case "FolderPaused", "FolderResumed":
            // These say `id` + `label`, not `folder` (upstream shape).
            guard let folder = event.folder ?? event.dataID else { return }
            let kind: StateChangeKind = event.type == "FolderPaused" ? .folderPaused
                                                                      : .folderResumed
            var group = context.stateChanges[kind] ?? Coalesced(time: event.time)
            let label = event.label.flatMap { $0.isEmpty ? nil : $0 } ?? folderLabel(for: folder)
            group.names.append(label)
            group.folderIDs.append(folder)
            group.time = event.time
            context.stateChanges[kind] = group
            return
        case "StateChanged":
            guard let folder = event.folder else { return }
            // Only the error transition is a row. Scans are deliberately
            // NOT recorded (class doc): the event cannot say why a folder
            // scanned, and rows we can't vouch for don't belong in the log.
            if event.to == "error" {
                context.errorFolders.append((folder, event.time))
            }
            return
        case "FolderWatchStateChanged":
            guard let folder = event.folder else { return }
            let label = folderLabel(for: folder)
            if let text = event.to, !text.isEmpty {
                context.entries.insert(Entry.daemonEvent(.watchFailed(text), time: event.time,
                                                         folderID: folder, folderLabel: label),
                                       at: 0)
            } else if let previous = event.from, !previous.isEmpty {
                context.entries.insert(Entry.daemonEvent(.watchRestored, time: event.time,
                                                         folderID: folder, folderLabel: label),
                                       at: 0)
            }
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
            // The bulk twin: this change was already counted by a bulk
            // recovery (index event first, at scale) — consume, don't log.
            if let budget = recoveredBulkBudget[folder], budget > 0 {
                recoveredBulkBudget[folder] = budget - 1
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
        // genuinely-lost events — retire them (their entries stand). The
        // bulk budget retires the same way.
        recoveredDetections = recoveredDetections.filter { $0.folder != folder }
        recoveredBulkBudget[folder] = nil

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

    /// Backstop-only: a bulk recovery also funds the budget the folder's
    /// late-arriving change events will consume (see `recoveredBulkBudget`).
    private func addBulkDetections(count: Int, folder: String, time: Date,
                                   to context: inout BatchContext) {
        var bulk = context.bulkDetected[folder] ?? (count: 0, time: time)
        bulk.count += count
        bulk.time = time
        context.bulkDetected[folder] = bulk
        recoveredBulkBudget[folder, default: 0] += count
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
    /// mention rate AND per wake (`deliveryCheckBudget`); costs nothing
    /// while no transfers end.
    private func resolvePendingDeliveryChecks(api: SyncthingAPI) {
        let pending = Array(pendingDeliveryChecks.prefix(Self.deliveryCheckBudget))
        pendingDeliveryChecks.removeFirst(pending.count)
        let epoch = logEpoch
        for check in pending {
            Task { @MainActor in
                guard let status = try? await api.fileStatus(folder: check.folder,
                                                             file: check.path),
                      status.availableOn.contains(check.device),
                      self.logEpoch == epoch else { return }   // loop still current
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
    // MARK: - Daemon events (folder & device rows)

    /// Emit the batch's pause/resume rows: one per subject, or one
    /// coalesced "N devices" / "N folders" row when a batch carried a burst
    /// (Pause All Devices fires one event per device).
    private func logStateChanges(_ context: inout BatchContext) {
        let order: [StateChangeKind] = [.devicePaused, .deviceResumed,
                                        .folderPaused, .folderResumed]
        for kind in order {
            guard let group = context.stateChanges[kind], !group.names.isEmpty else { continue }
            let entryKind: Entry.Kind
            switch kind {
            case .devicePaused: entryKind = .devicePaused
            case .deviceResumed: entryKind = .deviceResumed
            case .folderPaused: entryKind = .folderPaused
            case .folderResumed: entryKind = .folderResumed
            }
            let isFolder = kind == .folderPaused || kind == .folderResumed
            let entry: Entry
            if group.names.count == 1 {
                entry = Entry.daemonEvent(entryKind, time: group.time,
                                          folderID: isFolder ? group.folderIDs[0] : "",
                                          folderLabel: isFolder ? group.names[0] : "",
                                          party: isFolder ? nil : group.names[0])
            } else {
                let summary = "\(group.names.count) \(isFolder ? "folders" : "devices")"
                entry = Entry.daemonEvent(entryKind, time: group.time,
                                          folderLabel: isFolder ? summary : "",
                                          party: isFolder ? nil : summary,
                                          bulkCount: group.names.count)
            }
            context.entries.insert(entry, at: 0)
        }
    }

    /// A folder that entered `error`: StateChanged carries only the word,
    /// so one bounded status read fetches the text. A failed read still
    /// logs the fact, with a generic statement — the event happened.
    private func logFolderErrors(_ context: inout BatchContext, api: SyncthingAPI) async {
        for (folder, time) in context.errorFolders {
            let text = (try? await api.folderStatusError(id: folder)) ?? nil
            context.entries.insert(Entry.daemonEvent(.folderError(text ?? "Folder stopped with an error"),
                                                     time: time, folderID: folder,
                                                     folderLabel: folderLabel(for: folder)),
                                   at: 0)
        }
    }

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
