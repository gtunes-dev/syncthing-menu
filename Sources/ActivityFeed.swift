import Foundation

/// Live activity log for the Activity window: an append-only record of the
/// LOGICAL sync events witnessed while recording, newest first.
///
/// ## Intent
///
/// The window narrates, in real time, the sync lifecycle of every file whose
/// activity this device witnesses — so the person at the console can answer
/// "what is happening, and did my changes make it?" Use cases (Greg,
/// 2026-09-06 design review — these decide every trade-off below):
///
/// - Someone opens the window and WATCHES: specific activity, as it occurs,
///   not approximations.
/// - Someone wants to know what happened to ONE file: they type part of its
///   name and see its activity if it is still in the window. They never
///   fail to find it because the system collapsed it into a summary.
/// - Chattiness versus latency, and what to record or show, are the USER's
///   choices, added as controls later — never the system's.
///
/// Principles (settled 2026-08-17, principle 5 rewritten 2026-09-06):
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
/// 5. **Granularity is per item. Always.** Every witnessed file event is its
///    own row, at any scale; summarizing is a user option (not yet built),
///    never a system decision. (The one coalescing that remains is not of
///    files: a same-batch burst of device/folder pause-resume events — our
///    own Pause All verb — logs as "N devices"; its subject is the device,
///    nothing searchable is hidden.) Earlier generations coalesced "machine-scale"
///    bursts into "N changes" rows on the theory that a wall of rows helps
///    nobody — the design review of 2026-09-06 rejected that: the reader
///    decides what helps them, a collapsed row hides activity as it occurs,
///    and a file inside a summary can never be found by search. The costs
///    of per-item at scale are the store's job (`EntryLog`, O(1) per row)
///    and the window's (`windowSize`, a rolling bound the user will own).
///
/// ## The entries
///
/// Each entry is an immutable statement that something HAPPENED — a verb, an
/// item, a party, a time. Times are event times, never re-stamped; there is
/// no "superseded" (a newer change is simply a newer entry); eviction is
/// plain oldest-first at the window; entries are immutable in STATE but
/// enrichable in METADATA (an applied entry gains its author).
///
/// entry kind   | party            | evidence
/// -------------|------------------|---------------------------------------
/// detected     | This Mac         | LocalChangeDetected; or recovered BY NAME from LocalIndexUpdated's filenames (the backstop — batched, so it survives the ring overflow that eats per-file events)
/// sending      | recipient        | path APPEARS in the device's RemoteDownloadProgress state map
/// delivered    | recipient        | path DISAPPEARS from the state map + our index shows the device has it; or the path is absent from a COMPLETE remoteneed list; or a folder-level catch-up closes every open loop, per item; or the quiescence sweep confirms a stale loop
/// downloading  | author (late)    | ItemStarted not finished in the same batch
/// applied      | author           | ItemFinished ok (RemoteChangeDetected enriches, or creates when unwitnessed)
/// failed       | author (late)    | ItemFinished with an error
///
/// Same-batch collapse: ItemStarted + ItemFinished landing in ONE poll batch
/// (the normal case for small files) produce only the finished entry — one
/// file's fact, not two rows dated a millisecond apart. (This is one file's
/// start folding into its own end, not cross-file batching.)
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
/// catch-up, or the sweep instead. The Detected and Delivered rows are exact
/// per file; Sending is the best-effort middle.
///
/// **Delivery to ≥1 device closes a loop** (decided 2026-08-17 after a full
/// case enumeration — do not reopen without new evidence): a Detected entry
/// is an UNSCOPED beginning ("this Mac changed X" names no replica), so it
/// is owed exactly one ending — "X made it off this machine". Per-replica
/// endings still log wherever per-replica beginnings were witnessed (a
/// sending→Ada entry gets its delivered→Ada from direct transfer evidence,
/// ledger or not), and per-replica POSITION is a state question that lives
/// in Syncthing's own UI (Open Syncthing) — state, not activity, is never
/// this window's job.
///
/// ## The index backstop
///
/// LocalIndexUpdated is one BATCHED event per ~1000 index items, so it
/// survives the ring overflow that eats per-file change events during
/// churn. Items it reports that we did not witness are changes we never saw
/// — compared BY NAME against the witnessed-path set, because the event
/// carries the batch's `filenames`: when complete (count == items),
/// unwitnessed names become real per-item detected entries. When the names
/// are truncated or absent, only a count remains, and a count is not
/// specific activity: it is logged as a diagnostic, never as a row (the
/// spurious "1 change" rows of 2026-08-17 were exactly this slop rendered
/// as fact). Recovered entries default to .modified and an unknown item
/// kind; the real change event, arriving late, corrects both (the daemon
/// can emit LocalIndexUpdated BEFORE the change events it covers — observed
/// live 2026-08-18). And the event fires for items we RECEIVE too (docs:
/// "due to synchronizing one or more items from the cluster or discovering
/// local changes"): while a folder is pulling, index growth is the pull,
/// so the backstop stands down, and an inbound event for a path the
/// backstop already recovered un-fabricates that row (seen live
/// 2026-09-06 as "Detected 1,000 changes" for an inbound batch).
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
/// ## Boundaries at machine scale (honest omissions, not approximations)
///
/// The event ring holds 1000 events per subscription; a pull that outruns
/// our polling drops events, so some inbound rows go missing and a
/// Downloading can lose its Applied — the stream logs "missed N events".
/// The ledger caps open loops (`OutboundLedger.maxTrackedItems`); beyond it
/// the oldest loop is dropped and its ending omitted. The window evicts the
/// oldest rows beyond `windowSize`. None of these fabricates a row.
///
/// ## Daemon events (the third row family, added 2026-09-04)
///
/// Beyond file facts and recording markers, the log records what happened
/// to FOLDERS and DEVICES, from the daemon's own events, under one
/// selection test: would someone reading the log later want to know it
/// happened, and when? Live state stays the menu's job. Recorded: device
/// and folder pause/resume (a same-batch burst — our own Pause All verb —
/// coalesces to "N devices"; the subject is the device, not a file, so
/// nothing searchable is hidden), peers going online/offline, a folder
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
/// ergonomics to ship. Rows we can't vouch for don't belong in the log.
/// Evaluated and skipped, with reasons, in `.claude/notes` (progress
/// streams, FolderErrors' retry re-emission, startup events unobservable by
/// a fresh subscription, network/protocol internals). These rows are gated
/// by the display's own "folder & device events" switch and hidden under a
/// name search.
///
/// ## Lifecycle & frugality
///
/// The log holds ACTIVITY WITNESSED WHILE RECORDING — no seeding of any
/// kind (not history: delivery-blind; not the work queue: backlog is not
/// activity — standing state of any kind is Syncthing's own UI's job, via
/// Open Syncthing). Recording runs while it is WANTED — the policy says
/// always, or the window is open — AND POSSIBLE — the session has a live
/// endpoint; the long-poll loop (`EventStream`) exists exactly then, so
/// under the default policy a closed window is zero cost. Entries survive
/// everything short of an explicit clear; what a stop drops depends on WHY
/// it stopped:
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
            // that is the truth. Window eviction can orphan a marker — accepted.
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
            // one (an error text), else stays blank.
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
        /// devices").
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
        /// Folder-relative path; EMPTY for markers and daemon events (which
        /// are not items — and are therefore invisible to name search by
        /// design).
        let path: String
        /// What happened to the file. Add vs modify is indistinguishable
        /// from the API (both sides report new files as modified/update);
        /// rename arrives as delete + add (two entries). Enrichable for one
        /// reason only: a backstop-recovered entry guesses .modified
        /// (filenames carry no operation) and the real change event,
        /// arriving late, corrects it.
        var operation: Operation
        /// Daemon events only: how many subjects a coalesced "N devices" /
        /// "N folders" row stands for. nil for every file row.
        let bulkCount: Int?
        /// Display name of the entry's other party — the author ("This Mac"
        /// for local detections, the originating device for inbound entries;
        /// see principle 4) or, for sending/delivered, the recipient. The
        /// one enrichable field: inbound entries start nil (rendered "—")
        /// until the commit event identifies the author.
        var party: String?
        /// What kind of item this is, from the event's `type`. nil = not
        /// known — only backstop-recovered rows (a filename list carries no
        /// type). Enrichable: the real change event, arriving after a
        /// recovery, fills it in. Unknown renders as an EMPTY icon slot,
        /// never a guess or an "unknown" glyph (lag, never lie; no non-data
        /// ink).
        var itemType: ItemType? = nil

        enum ItemType: Equatable {
            case file
            case directory
            case symlink

            /// The events' `type` field: "file" / "dir" / "symlink".
            init?(apiType: String?) {
                switch apiType {
                case "file": self = .file
                case "dir", "directory": self = .directory
                case "symlink": self = .symlink
                default: return nil
                }
            }
        }

        /// The Name column's text: the path, or a non-file row's statement.
        var displayName: String {
            kind.statement ?? path
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

    typealias ItemKey = EntryLog.ItemKey

    // MARK: - Published state & tuning

    /// Newest first: the display's snapshot of the log, rebuilt at each
    /// commit. Bounded by `windowSize`.
    @Published private(set) var entries: [Entry] = []

    /// The window: how many rows the log keeps, and therefore both what the
    /// user can scroll or search and what the log holds in memory — ONE
    /// number by decision (2026-09-06), to become a user setting. 5,000 is
    /// chosen so a human-scale batch (a folder of a couple of thousand
    /// files, listed per item) does not evict the rest of a day's history
    /// under always-on recording, while staying trivial in memory (~1 MB)
    /// and in the per-commit snapshot and the view's sort and search.
    static let windowSize = 5_000
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

    /// Nonisolated so the owner (a nonisolated app delegate) can create the
    /// feed at construction time. `windowSize` is injectable for tests only;
    /// the app uses the constant.
    nonisolated init(windowSize: Int = ActivityFeed.windowSize) {
        log = EntryLog(capacity: windowSize)
    }

    /// Injectable seams (the monitor's established pattern): tests exercise
    /// the retry path and the sweep's staleness clock without real time.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    var now: () -> Date = Date.init

    // MARK: - Private state

    /// The log itself (rows, order, window, per-item index); `entries` is
    /// its display snapshot.
    private var log: EntryLog

    /// Rows produced OUTSIDE the batch pipeline: markers (window, policy,
    /// and session flips) and the fire-and-forget delivery checks'
    /// confirmations. A batch works on a COPY of the log taken at its start
    /// and parks on network reads mid-way, so committing straight onto
    /// `log` while a batch is in flight would be overwritten by that
    /// batch's commit — the lost-Delivered race (review, 2026-09-07): the
    /// ledger loop is already closed, so the ending is gone for good. Rule:
    /// with a batch in flight, out-of-band rows QUEUE and the batch folds
    /// them in before its commit; with none in flight, markers commit at
    /// once (their callers read `entries` synchronously) and deliveries
    /// drain on one scheduled turn (collapsing a burst of checks into one
    /// snapshot). Queued deliveries belong with their loops: a pause or
    /// clear flushes them along with the ledger, while a restart or
    /// disconnect keeps both (the check already closed the loop, so
    /// dropping the row would lose the ending — re-review, 2026-09-07).
    /// Markers describe the log's own transitions and always land. Batches
    /// are COUNTED, not flagged: a cancelled loop's batch can still be
    /// unwinding when its successor's first batch starts.
    private var batchesInFlight = 0
    private var pendingMarkers: [Entry] = []
    private var pendingDeliveries: [ConfirmedDelivery] = []
    private var deliveryDrainScheduled = false

    private struct ConfirmedDelivery {
        let folder: String
        let path: String
        let operation: Entry.Operation
        let itemType: Entry.ItemType?
        let party: String
        let time: Date
    }

    private var api: SyncthingAPI?
    private var windowVisible = false
    private(set) var recordingPolicy: ActivityRecordingPolicy = .whileWindowOpen
    /// Whether recording is WANTED (policy or window), independent of the
    /// endpoint. Stored so a flip can be told from a repeat — the window
    /// controller and the session both re-announce unchanged states — and
    /// a flip to off is what flushes the open loops (a pause).
    private var isDesired = false
    private var stream: EventStream<SyncthingAPI.ActivityEvent>?
    /// Bumped whenever the log is INVALIDATED from outside the batch
    /// pipeline (loop start/stop, clear). A batch parks on network awaits
    /// mid-way and commits a working copy taken at its start; it commits
    /// only if the epoch it started under is still current, so a pause or
    /// clear landing while a batch is parked is never overwritten by that
    /// batch. The same guard retires the fire-and-forget delivery checks of
    /// a stopped loop. Markers do NOT bump it — they append, and go through
    /// the out-of-band queue instead (see `pendingMarkers`).
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
    /// are recovered as named detections. Bounded: cleared at every index
    /// event, which the daemon emits at least once per ~1000 items.
    private var witnessedSinceIndexUpdate: [String: Set<String>] = [:]
    /// Per-folder sweep throttle (`sweepMinInterval`).
    private var lastSweep: [String: Date] = [:]
    /// Paths whose detected entry came from backstop RECOVERY, awaiting the
    /// real event: LocalChangeDetected consumes the marker and corrects the
    /// entry instead of logging a duplicate; an INBOUND event consumes it
    /// and removes the entry (the index growth was a pull). Markers for a
    /// folder are cleared at its next index event, so a marker never
    /// outlives one index cycle and a genuinely new later change always
    /// logs.
    private var recoveredDetections: Set<ItemKey> = []
    /// Folders currently in a syncing state per StateChanged (not seeded):
    /// the backstop stands down for them.
    private var syncingFolders: Set<String> = []
    private static let syncingStates: Set<String> = ["syncing", "sync-preparing", "sync-waiting"]

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

    /// Markers land outside the batch pipeline (see `pendingMarkers`): a
    /// parked batch folds them in; otherwise they commit at once.
    private func appendMarker(_ kind: Entry.Kind) {
        let marker = Entry.marker(kind, time: now())
        if batchesInFlight > 0 {
            pendingMarkers.append(marker)
        } else {
            var updated = log
            updated.append(marker)
            commit(updated)
        }
    }

    /// The user's Clear: empty the log and flush the open loops (a cleared
    /// log must not later receive a delivered whose detected the user
    /// removed). No marker — an empty log explains itself. Recording, if
    /// running, continues: only the batch parked right now, if any, is
    /// dropped (epoch).
    func clear() {
        logEpoch += 1
        log.removeAll()
        entries = []
        pendingMarkers = []   // a transition queued before the clear belongs to the cleared log
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
        pendingDeliveries = []   // confirmed endings for loops that no longer exist
        reportedDownloads = [:]
        witnessedSinceIndexUpdate = [:]
        recoveredDetections = []
        lastSweep = [:]
        syncingFolders = []
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
                // A (re)seed means the stream (re)started: per-tick state is
                // unknowable across the gap. Open LOOPS stay — the sweep and
                // the confirmation queries are computed against live truth,
                // so they remain sound (and the sweep is exactly what closes
                // loops whose confirming events fell into the gap).
                self.reportedDownloads = [:]
                self.witnessedSinceIndexUpdate = [:]
                self.recoveredDetections = []
                self.syncingFolders = []
                try await self.refreshIdentity(api: api)   // also seeds syncingFolders
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
        // Folders already pulling when the loop starts: the backstop must
        // stand down for them from the first index event, not from the next
        // syncing transition (review finding, 2026-09-07). One small read
        // per folder, tolerant — an unreadable (paused) folder is not syncing.
        for folder in folders where !(folder.paused ?? false) {
            if let state = try? await api.folderState(id: folder.id),
               Self.syncingStates.contains(state) {
                syncingFolders.insert(folder.id)
            }
        }
    }

    // MARK: - Batch processing

    /// Everything one poll batch accumulates before it commits: the working
    /// copy of the log plus the batch-scoped context the individual event
    /// handlers need.
    private struct BatchContext {
        var log: EntryLog
        /// Downloading entries created in THIS batch, so a finish arriving
        /// moments later collapses with its start (same-batch collapse).
        var startedThisBatch: [ItemKey: UUID] = [:]
        /// (folder, device) pairs whose FolderCompletion moved this batch —
        /// the remoteneed confirmation cue, deduped per batch.
        var deliveryTriggers: [TransferKey: Date] = [:]
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
    /// 1. per-event application (rows, ledger, triggers)
    /// 2. the batch's coalesced daemon-event rows and folder-error reads
    /// 3. remoteneed confirmations for this batch's completion triggers
    /// 4. the quiescence sweep, if any open loop has gone stale
    /// 5. commit, then the fire-and-forget availability checks
    /// 6. housekeeping: identity refresh when ConfigSaved arrived
    private func handleBatch(_ events: [SyncthingAPI.ActivityEvent],
                             api: SyncthingAPI) async {
        let epoch = logEpoch
        batchesInFlight += 1
        var context = BatchContext(log: log)

        // NOTE: the per-event handlers write ROWS to the working copy but
        // their bookkeeping (ledger, witnessed/recovered sets, connected
        // ids, transfer baselines, delivery-check queue) straight to self.
        // A batch dropped by the epoch guard therefore leaves that
        // bookkeeping ahead of the log. The drop paths are pause and clear
        // (which flush all of it) and a loop restart on a session republish
        // (whose reseed clears the per-tick state; the ledger may then hold
        // loops whose detected row never landed — they close as delivered
        // rows without a beginning, a settled fact, and connected-set flips
        // are re-read at seed). Accepted rather than copying a 100k-loop
        // ledger per batch (review, 2026-09-07).
        for event in events {
            apply(event, to: &context)
        }
        logStateChanges(&context)
        await logFolderErrors(&context, api: api)
        await confirmDeliveries(context.deliveryTriggers, api: api, log: &context.log)
        await sweepStaleLoops(api: api, log: &context.log)
        batchesInFlight -= 1
        // The awaits above parked this batch; if the log was replaced
        // underneath (pause, clear, loop restart) its working copy is stale
        // — drop it rather than overwrite what happened meanwhile. Rows
        // queued meanwhile still need a home (a pause or clear has already
        // flushed the deliveries it invalidated).
        guard logEpoch == epoch else {
            drainPendingRows()
            return
        }
        foldPendingRows(into: &context.log)
        commit(context.log)
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
            context.log.append(Entry.daemonEvent(.deviceOnline, time: event.time,
                                                 party: displayName(forFullID: device)))
            return
        case "DeviceDisconnected":
            guard let device = event.device, device != myID else { return }
            guard connectedIDs.remove(device) != nil else { return }
            context.log.append(Entry.daemonEvent(.deviceOffline, time: event.time,
                                                 party: displayName(forFullID: device)))
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
            // Syncing transitions gate the index backstop (class doc).
            if let to = event.to, Self.syncingStates.contains(to) {
                syncingFolders.insert(folder)
            } else if event.to == "idle" {
                syncingFolders.remove(folder)
            }
            return
        case "FolderWatchStateChanged":
            guard let folder = event.folder else { return }
            let label = folderLabel(for: folder)
            if let text = event.to, !text.isEmpty {
                context.log.append(Entry.daemonEvent(.watchFailed(text), time: event.time,
                                                     folderID: folder, folderLabel: label))
            } else if let previous = event.from, !previous.isEmpty {
                context.log.append(Entry.daemonEvent(.watchRestored, time: event.time,
                                                     folderID: folder, folderLabel: label))
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
        let itemType = Entry.ItemType(apiType: event.itemKind)
        // Every item event witnesses its name for the index backstop: local
        // changes AND inbound items (our index grows from pulls too).
        witnessedSinceIndexUpdate[folder, default: []].insert(path)

        if event.type != "LocalChangeDetected", recoveredDetections.remove(key) != nil {
            // An inbound item the backstop ALREADY recovered as a local
            // detection — index event first, pull second: un-fabricate it.
            // The row and its outbound loop describe a change that never
            // happened here.
            if let row = context.log.newest(for: key), row.kind == .detected,
               row.party == "This Mac" {
                context.log.remove(id: row.id)
            }
            _ = ledger.closeItem(folder: folder, path: path)
        }

        switch event.type {
        case "LocalChangeDetected":
            // The backstop already logged this change (recovery from an
            // index event that arrived first): consume the marker — the
            // entry exists, a second would be a duplicate of the same fact.
            // But the recovery GUESSED .modified and knew no item kind; this
            // event knows both — correct the entry and the open loop, or a
            // real delete renders as a modify all the way through delivery
            // (regressed and caught live 2026-08-18).
            if recoveredDetections.remove(key) != nil {
                if let row = context.log.newest(for: key), row.kind == .detected {
                    context.log.update(id: row.id) {
                        $0.operation = operation
                        $0.itemType = itemType
                    }
                }
                ledger.annotate(folder: folder, path: path, operation: operation,
                                itemType: itemType)
                return
            }
            context.log.append(Entry(time: event.time, kind: .detected,
                                     folderID: folder, folderLabel: label,
                                     path: path, operation: operation,
                                     bulkCount: nil, party: "This Mac",
                                     itemType: itemType))
            // A loop opens only where delivery is possible in principle
            // (principle 3): on a receive-only or unshared folder the
            // detected entry stands alone — opening a loop there would
            // synthesize a false "delivered" the moment a remote reads
            // completion 100.
            if deliverableFolders.contains(folder) {
                ledger.track(folder: folder, path: path, operation: operation,
                             itemType: itemType, at: now())
            }

        case "ItemStarted":
            // A second start for the same item in one batch (a retry with
            // no finish between) replaces the first: one in-flight row.
            if let earlier = context.startedThisBatch[key] {
                context.log.remove(id: earlier)
            }
            let entry = Entry(time: event.time, kind: .downloading, folderID: folder,
                              folderLabel: label, path: path, operation: operation,
                              bulkCount: nil, party: nil, itemType: itemType)
            context.log.append(entry)
            context.startedThisBatch[key] = entry.id

        case "ItemFinished":
            let kind: Entry.Kind = event.error.map { .failed($0) } ?? .applied
            // Same-batch collapse: replace the start logged moments ago
            // rather than keeping both halves of one sub-batch fact.
            if let startID = context.startedThisBatch.removeValue(forKey: key) {
                context.log.remove(id: startID)
            }
            context.log.append(Entry(time: event.time, kind: kind, folderID: folder,
                                     folderLabel: label, path: path,
                                     operation: operation, bulkCount: nil,
                                     party: nil, itemType: itemType))

        case "RemoteChangeDetected":
            let author = event.modifiedBy.map { deviceNames[$0] ?? $0 }
            // The commit event names the author — enrich the applied entry
            // still awaiting one (metadata enrichment, never a state change).
            if let row = context.log.newest(for: key), row.kind == .applied,
               row.party == nil {
                context.log.update(id: row.id) { $0.party = author }
            } else {
                // A commit with no witnessed apply (e.g. subscription started
                // mid-apply): still a real, settled inbound change.
                context.log.append(Entry(time: event.time, kind: .applied,
                                         folderID: folder, folderLabel: label,
                                         path: path, operation: operation,
                                         bulkCount: nil, party: author,
                                         itemType: itemType))
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
        // Reverse-sorted so the newest-first display shows a burst of
        // appearances in path order.
        for path in reported.subtracting(previous).sorted().reversed() {
            // Always a FILE: directories and symlinks have no blocks and never
            // appear in a progress report — they go detected → delivered.
            context.log.append(Entry(time: event.time, kind: .sending,
                                     folderID: folder, folderLabel: label,
                                     path: path, operation: .modified,
                                     bulkCount: nil, party: party,
                                     itemType: .file))
            ledger.track(folder: folder, path: path, operation: .modified,
                         itemType: .file, at: now())
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
            // confirmed, per item (the person at the console needs WHICH
            // items completed, not "caught up"). needDeletes must be zero
            // too: a deletes-only backlog can report completion 100 with
            // tombstones still undelivered.
            let closed = ledger.closeFolder(folder)
            guard !closed.isEmpty else { return }
            logClosure(closed, folder: folder, party: displayName(forFullID: device),
                       time: event.time, into: &context.log)
            Log.monitor.log("activity catch-up: \(closed.count) items confirmed by \(device.prefix(7), privacy: .public)")
        } else {
            // Partial progress: cue for one bounded remoteneed read.
            context.deliveryTriggers[TransferKey(folder: folder, device: device)]
                = event.time
        }
    }

    private func isFullCatchUp(_ event: SyncthingAPI.ActivityEvent) -> Bool {
        event.completion == 100 && event.needItems == 0 && (event.needDeletes ?? 0) == 0
    }

    // MARK: - The index backstop

    /// See the class doc, "The index backstop": named recovery of index items
    /// we did not witness, per item; counts alone are diagnostics; stands
    /// down while the folder pulls.
    private func applyIndexUpdateBackstop(_ event: SyncthingAPI.ActivityEvent,
                                          to context: inout BatchContext) {
        guard let folder = event.folder, let items = event.items else { return }
        let witnessed = witnessedSinceIndexUpdate.removeValue(forKey: folder) ?? []
        // A new index cycle: change events covered by the PREVIOUS cycle
        // have long since arrived, so unconsumed recovery markers are
        // genuinely-lost events — retire them (their entries stand).
        recoveredDetections = recoveredDetections.filter { $0.folder != folder }
        // While the folder is pulling, index growth IS the pull (class doc).
        guard !syncingFolders.contains(folder) else { return }

        if let filenames = event.filenames, filenames.count == items {
            let unwitnessed = filenames.filter { !witnessed.contains($0) }
            guard !unwitnessed.isEmpty else { return }
            recoverDetections(unwitnessed, folder: folder, time: event.time, to: &context)
            Log.monitor.log("activity backstop: \(unwitnessed.count) unwitnessed changes recovered by name")
        } else {
            // Count only — not specific activity. A diagnostic, never a row.
            let surplus = items - witnessed.count
            if surplus > 0 {
                Log.monitor.log("activity backstop: \(surplus) unnamed surplus items (not logged)")
            }
        }
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
            let key = ItemKey(folder: folder, path: path)
            if let newest = context.log.newest(for: key), newest.kind == .detected { continue }
            context.log.append(Entry(time: time, kind: .detected, folderID: folder,
                                     folderLabel: label, path: path,
                                     operation: .modified, bulkCount: nil,
                                     party: "This Mac"))
            recoveredDetections.insert(key)
            if deliverableFolders.contains(folder) {
                ledger.track(folder: folder, path: path, operation: .modified, at: now())
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
                                   api: SyncthingAPI, log: inout EntryLog) async {
        for (key, time) in triggers {
            guard ledger.hasTrackedItems(in: key.folder) else { continue }
            guard let need = try? await api.remoteNeed(folder: key.folder,
                                                       device: key.device),
                  need.complete else { continue }
            let closed = ledger.closeItems(in: key.folder, absentFrom: need.needed)
            guard !closed.isEmpty else { continue }
            logClosure(closed, folder: key.folder, party: displayName(forFullID: key.device),
                       time: time, into: &log)
            Log.monitor.log("activity remoteneed: \(closed.count) deliveries confirmed by \(key.device.prefix(7), privacy: .public)")
        }
    }

    /// The quiescence sweep (see the class doc): close loops whose
    /// event-driven ending never arrived. Probes our own daemon's index —
    /// one completion read per stale folder × connected device; a caught-up
    /// device closes everything, partial progress falls back to remoteneed
    /// for per-item closure. Runs on the wakes the stream already makes;
    /// costs nothing while no loops are open or none is stale.
    private func sweepStaleLoops(api: SyncthingAPI, log: inout EntryLog) async {
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
                    let closed = ledger.closeFolder(folder)
                    if !closed.isEmpty {
                        logClosure(closed, folder: folder,
                                   party: displayName(forFullID: device),
                                   time: now(), into: &log)
                        Log.monitor.log("activity sweep: closed \(closed.count) items — \(device.prefix(7), privacy: .public) caught up")
                    }
                    break   // folder fully closed; no more probing needed
                } else if ledger.hasTrackedItems(in: folder),
                          let need = try? await api.remoteNeed(folder: folder,
                                                               device: device),
                          need.complete {
                    let closed = ledger.closeItems(in: folder, absentFrom: need.needed)
                    guard !closed.isEmpty else { continue }
                    logClosure(closed, folder: folder,
                               party: displayName(forFullID: device),
                               time: now(), into: &log)
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
                let item = self.ledger.closeItem(folder: check.folder, path: check.path)
                // Never straight onto the log (see `pendingDeliveries`).
                self.enqueueDelivery(ConfirmedDelivery(
                    folder: check.folder, path: check.path,
                    operation: item?.operation ?? .modified,
                    itemType: item?.itemType ?? .file,   // a transfer: a file
                    party: self.displayName(forFullID: check.device),
                    time: check.time))
            }
        }
    }

    // MARK: - Out-of-band rows (markers, confirmed deliveries)

    private func enqueueDelivery(_ delivery: ConfirmedDelivery) {
        pendingDeliveries.append(delivery)
        guard batchesInFlight == 0, !deliveryDrainScheduled else { return }
        // One turn later: a burst of checks resolving together becomes one
        // snapshot instead of one per check.
        deliveryDrainScheduled = true
        Task { @MainActor in
            self.deliveryDrainScheduled = false
            self.drainPendingRows()
        }
    }

    /// Fold queued rows into the live log and publish — only when no batch
    /// is in flight (a batch folds them itself before its commit).
    private func drainPendingRows() {
        guard batchesInFlight == 0, !(pendingMarkers.isEmpty && pendingDeliveries.isEmpty)
        else { return }
        var updated = log
        foldPendingRows(into: &updated)
        commit(updated)
    }

    /// Everything queued lands (pause and clear flush the delivery queue
    /// with the ledger; nothing else invalidates a confirmed delivery).
    private func foldPendingRows(into log: inout EntryLog) {
        for marker in pendingMarkers { log.append(marker) }
        pendingMarkers = []
        let deliveries = pendingDeliveries
        pendingDeliveries = []
        for delivery in deliveries {
            insertDelivered(folder: delivery.folder, path: delivery.path,
                            operation: delivery.operation, itemType: delivery.itemType,
                            party: delivery.party, time: delivery.time, into: &log)
        }
    }

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
            context.log.append(entry)
        }
    }

    /// A folder that entered `error`: StateChanged carries only the word,
    /// so one bounded status read fetches the text. A failed read still
    /// logs the fact, with a generic statement — the event happened.
    private func logFolderErrors(_ context: inout BatchContext, api: SyncthingAPI) async {
        for (folder, time) in context.errorFolders {
            let text = (try? await api.folderStatusError(id: folder)) ?? nil
            context.log.append(Entry.daemonEvent(.folderError(text ?? "Folder stopped with an error"),
                                                 time: time, folderID: folder,
                                                 folderLabel: folderLabel(for: folder)))
        }
    }

    // MARK: - Delivered rows

    /// Convert closed loops into delivered rows, per item. Reverse-sorted so
    /// the newest-first display shows the closure in path order.
    private func logClosure(_ closed: [(path: String, item: OutboundLedger.Item)],
                            folder: String, party: String, time: Date,
                            into log: inout EntryLog) {
        for (path, item) in closed.reversed() {
            insertDelivered(folder: folder, path: path, operation: item.operation,
                            itemType: item.itemType, party: party, time: time, into: &log)
        }
    }

    /// One delivered entry per (path, device) fact PER EPISODE. The
    /// confirmation paths overlap by design (remoteneed, the availability
    /// check, catch-up, and the sweep can each prove the same delivery), so
    /// a delivery is suppressed when the path's CURRENT episode — since its
    /// newest detected/sending row — already has a delivered row for this
    /// party (`EntryLog` tracks that per item). An older episode's delivered
    /// never swallows a re-changed path's new fact (session-wide dedupe
    /// silently ate every re-churned file's delivery after its first — the
    /// Photos bug, diagnosed from live logs 2026-08-17).
    private func insertDelivered(folder: String, path: String,
                                 operation: Entry.Operation,
                                 itemType: Entry.ItemType? = nil, party: String,
                                 time: Date, into log: inout EntryLog) {
        let key = ItemKey(folder: folder, path: path)
        guard !log.isDelivered(key, to: party) else { return }
        log.append(Entry(time: time, kind: .delivered, folderID: folder,
                         folderLabel: folderLabel(for: folder), path: path,
                         operation: operation, bulkCount: nil, party: party,
                         itemType: itemType))
    }

    /// Publish a working copy: the log itself and its newest-first snapshot.
    private func commit(_ updated: EntryLog) {
        log = updated
        let snapshot = updated.snapshot
        if snapshot != entries { entries = snapshot }
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
