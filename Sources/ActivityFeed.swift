import Foundation

/// Live change-activity feed for the Activity window: what this device is
/// doing, one row per file per sync episode (newest first).
///
/// ## Row model (the internal reference table)
///
/// A row carries three orthogonal facts, each its own column in the UI:
/// - **Operation** (static): modified | deleted — pencil / trash glyph.
///   (Add vs modify is NOT distinguishable from the API — see notes.)
/// - **Origin** (static): "This Mac" (`isLocalOrigin`) or the originating
///   device's name (`origin`, from RemoteChangeDetected's modifiedBy).
/// - **State** (the ONLY dynamic fact; a glyph beside the operation glyph so
///   the pair reads as one compound fact): where the change is in its
///   journey between devices.
///
/// state      | glyph                     | direction | entered by                          | exits to
/// -----------|---------------------------|-----------|-------------------------------------|------------------------
/// pending    | clock                     | outbound  | LocalChangeDetected (modify OR delete) | uploading, synced, superseded
/// uploading  | arrow.triangle.2.circlepath | outbound | RemoteDownloadProgress names the path | synced, superseded, pending (stale ~15s)
/// synced     | arrow.up                  | outbound  | FolderCompletion full catch-up (≥1 dev) | —
/// superseded | clock.badge.xmark         | outbound  | newer episode for same path         | —
/// syncing    | arrow.triangle.2.circlepath | inbound | ItemStarted                         | applied, failed
/// applied    | arrow.down                | inbound   | ItemFinished ok; RemoteChangeDetected stamps origin | —
/// failed     | exclamationmark.triangle  | inbound   | ItemFinished(error)                 | syncing (retry = new row)
///
/// uploading caveats (RemoteDownloadProgress semantics): the remote reports
/// every ~5s, so sub-5s transfers never show it (clock → arrow.up direct);
/// deletes never show it (tombstones carry no content); there is no end
/// event — a row not re-confirmed for ~15s reverts to pending; and in a 3+
/// device cluster the fetching peer may be pulling from a third replica.
///
/// Notes pinned to the table:
/// - Add vs modify is indistinguishable (both sides report new files as
///   modified/update); rename arrives as delete + add (two rows).
/// - "synced" means delivered to AT LEAST ONE remote device (the change
///   survives losing this machine) — not cluster-wide convergence. Local
///   DELETES travel the same pending→synced journey (tombstone delivery).
/// - Delivery is confirmed at FOLDER granularity: a FolderCompletion from
///   any remote device reporting full catch-up (completion == 100 AND
///   needItems == 0) flips every awaiting row in the folder. No per-file
///   upload event exists, and FolderCompletion.sequence lives in the REMOTE
///   device's own number-space (verified live 2026-07-24) — a cross-device
///   sequence comparison is unsound and was removed. Rows therefore flip
///   together when a peer finishes the folder, not per-file as items land;
///   per-file truth would require /rest/db/remoteneed queries (deliberately
///   not built).
/// - Inbound rows don't know their origin until the commit event lands —
///   the Origin column shows "—" while a download is in flight.
///
/// Frugality contract: the long-poll loop runs ONLY while the Activity window
/// is visible and the session is connected. Closed window = zero cost; the
/// daemon's `/rest/events/disk` ring provides history to seed from on open.
/// Offline peers cost nothing: watermark flips are driven by events arriving
/// on the same parked long-poll, never by per-row queries.
///
/// Main-thread confined, like `SyncthingMonitor`: the poll task is @MainActor,
/// awaits run the network work off-main, all state mutation stays on main.
@MainActor
final class ActivityFeed: ObservableObject {
    struct Row: Identifiable, Equatable {
        enum Operation: Equatable {
            case modified
            case deleted
        }

        enum JourneyState: Equatable {
            // Outbound (local-origin) journey
            case pending            // committed locally, awaiting delivery to a peer
            case uploading          // a remote is actively fetching it right now
            case synced             // delivered to ≥1 remote device
            case superseded         // overtaken before delivery — never left
            // Inbound (remote-origin) journey
            case syncing            // apply in flight
            case applied            // remote change applied here
            case failed(String)     // apply failed (ItemFinished error text)

            /// Still awaiting delivery — the states the watermark can flip
            /// and a newer episode can supersede.
            var isAwaitingDelivery: Bool {
                self == .pending || self == .uploading
            }
        }

        let id = UUID()
        var time: Date
        let folderID: String
        var folderLabel: String
        let path: String
        /// true = a local edit heading out; false = a remote change applied here.
        let isLocalOrigin: Bool
        /// What happened to the file. Static for the life of the row.
        var operation: Operation
        /// Where the change is in its journey. The only fact that changes.
        var state: JourneyState
        /// Display name of the device that originated the change (inbound
        /// rows, once the commit event lands). nil = local origin or unknown.
        var origin: String?
        /// Episode still expects events (started → finished → committed).
        var episodeOpen: Bool
        /// When RemoteDownloadProgress last confirmed the uploading state —
        /// there is no end event, so staleness (see `uploadStaleAfter`)
        /// reverts uploading → pending.
        var uploadRefreshedAt: Date?

        // MARK: Sort keys (display sorting reads these via KeyPathComparator)

        /// The Changed By column's display string — also its sort key, so
        /// the cell and the comparator share one definition.
        var originDisplay: String {
            isLocalOrigin ? "This Mac" : (origin ?? "—")
        }

        /// Modifies before deletes when ascending.
        var operationSortKey: Int {
            operation == .modified ? 0 : 1
        }

        /// Attention order: ascending puts problems first — failed, then
        /// in-flight, then waiting, then settled.
        var stateSortKey: Int {
            switch state {
            case .failed: 0
            case .syncing: 1
            case .uploading: 2
            case .pending: 3
            case .superseded: 4
            case .applied: 5
            case .synced: 6
            }
        }
    }

    /// Newest first. Bounded (`maxRows`) — the window is a recent-activity
    /// readout, not a log archive.
    @Published private(set) var rows: [Row] = []

    private static let pollTimeout = 50
    private static let maxRows = 500
    private static let historySeed = 100
    /// 3 missed RemoteDownloadProgress cadences (~5s each): the transfer
    /// ended or the peer vanished — stop claiming "uploading".
    private static let uploadStaleAfter: TimeInterval = 15

    /// All stored properties have defaults; nonisolated so the owner (a
    /// nonisolated app delegate) can create the feed at construction time.
    nonisolated init() {}

    /// Injectable seams (the monitor's established pattern): tests exercise
    /// the retry path and the upload-staleness clock without real time.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    var now: () -> Date = Date.init

    private var api: SyncthingAPI?
    private var windowVisible = false
    private var task: Task<Void, Never>?
    /// Folder id → display label, refreshed at each loop (re)start; the item
    /// events carry only the folder id.
    private var folderLabels: [String: String] = [:]
    /// Short device id (the 7-char prefix modifiedBy carries) → display name.
    private var deviceNames: [String: String] = [:]
    /// This device's id — FolderCompletion events for the local device (if the
    /// daemon ever emits them) must not flip the watermark.
    private var myID: String?

    /// Session fan-out, mirroring `SyncthingMonitor`: safe to call on every
    /// publish (restarts the loop against the fresh endpoint if active).
    func connect(api: SyncthingAPI) {
        self.api = api
        if windowVisible { startLoop() }
    }

    /// The daemon is gone; its event stream and subscriptions died with it.
    /// Rows stay — history remains readable in the open window.
    func disconnect() {
        api = nil
        stopLoop()
    }

    /// The window controller's visibility signal — the feature's on/off switch.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        if visible { startLoop() } else { stopLoop() }
    }

    private func startLoop() {
        guard let api else { return }
        stopLoop()
        task = Task { @MainActor in await self.run(api: api) }
    }

    private func stopLoop() {
        task?.cancel()
        task = nil
    }

    @MainActor
    private func run(api: SyncthingAPI) async {
        var since = 0
        var needsSetup = true
        while !Task.isCancelled {
            do {
                if needsSetup {
                    // Cursor first (also creates the server-side subscription);
                    // a change landing during the seed has an id past the
                    // cursor and arrives in the first long-poll — no gap.
                    since = try await api.activityEvents(since: 0, timeout: 1, limit: 1)
                        .last?.id ?? 0
                    folderLabels = Dictionary(uniqueKeysWithValues: (try await api.folders())
                        .map { ($0.id, $0.label.isEmpty ? $0.id : $0.label) })
                    let devices = try await api.devices()
                    deviceNames = Dictionary(uniqueKeysWithValues: devices.map {
                        (String($0.deviceID.prefix(7)),
                         ($0.name?.isEmpty ?? true) ? String($0.deviceID.prefix(7)) : $0.name!)
                    })
                    myID = try await api.myID()
                    // Seed display history only when starting empty (first open
                    // this daemon-session); a reconnect keeps what's shown
                    // rather than risking duplicate rows.
                    if rows.isEmpty {
                        seedHistory(try await api.diskEvents(limit: Self.historySeed))
                    }
                    needsSetup = false
                }
                let events = try await api.activityEvents(since: since,
                                                          timeout: Self.pollTimeout)
                guard !Task.isCancelled else { return }
                if let first = events.first, since > 0, first.id > since + 1 {
                    // Ring overflow: the daemon buffers 1000 events per
                    // subscription and we fell behind. Rows between are lost;
                    // the feed continues from here. (A visible discontinuity
                    // marker is a candidate refinement.)
                    Log.monitor.log("activity stream missed \(first.id - since - 1) events")
                }
                var updated = rows
                for event in events {
                    since = max(since, event.id)
                    apply(event, to: &updated)
                }
                // Every wake (including empty ~50s timeouts) sweeps stale
                // uploading rows back to pending — there's no end event.
                revertStaleUploads(&updated)
                commit(updated)
            } catch {
                guard !Task.isCancelled else { return }
                // Daemon unreachable or mid-restart: event ids reset with the
                // worker, so drop the cursor and rebuild. No endpoint-suspect
                // escalation here — SyncthingMonitor is the session's health
                // probe; if the daemon is really gone the session flips
                // unavailable and disconnects us.
                since = 0
                needsSetup = true
                await retrySleep(2_000_000_000)
            }
        }
    }

    // MARK: - Row lifecycle

    /// Merge one event into the row list. See the state table in the class
    /// doc — this function IS that table's transition column.
    private func apply(_ event: SyncthingAPI.ActivityEvent, to rows: inout [Row]) {
        switch event.type {
        case "FolderCompletion":
            applyWatermark(event, to: &rows)
            return
        case "RemoteDownloadProgress":
            markUploading(event, in: &rows)
            return
        default:
            break
        }

        guard let folder = event.folder, let path = event.path else { return }
        let label = event.label ?? folderLabels[folder] ?? folder
        let isDelete = event.action == "delete" || event.action == "deleted"
        let operation: Row.Operation = isDelete ? .deleted : .modified

        func openIndex() -> Int? {
            rows.firstIndex { $0.episodeOpen && $0.folderID == folder && $0.path == path }
        }
        /// A new episode for a path outruns any undelivered local edit of it:
        /// that content will never reach anyone.
        func supersedePending() {
            for index in rows.indices
            where rows[index].state.isAwaitingDelivery && rows[index].folderID == folder
                && rows[index].path == path {
                rows[index].state = .superseded
                rows[index].uploadRefreshedAt = nil
            }
        }
        func insert(_ row: Row) {
            rows.insert(row, at: 0)
        }

        switch event.type {
        case "ItemStarted":
            // A retry of a failed/stale episode restarts it at the top rather
            // than mutating an old row in place — chronology wins.
            if let index = openIndex() { rows.remove(at: index) }
            supersedePending()
            insert(Row(time: event.time, folderID: folder, folderLabel: label, path: path,
                       isLocalOrigin: false, operation: operation, state: .syncing,
                       origin: nil, episodeOpen: true))

        case "ItemFinished":
            let state: Row.JourneyState = event.error.map { .failed($0) } ?? .applied
            if let index = openIndex() {
                rows[index].state = state
                rows[index].operation = operation
                rows[index].time = event.time
                // Success keeps the episode open for the commit event's
                // `modifiedBy`; failure ends it (no commit will come).
                if event.error != nil { rows[index].episodeOpen = false }
            } else {
                supersedePending()
                insert(Row(time: event.time, folderID: folder, folderLabel: label, path: path,
                           isLocalOrigin: false, operation: operation, state: state,
                           origin: nil, episodeOpen: event.error == nil))
            }

        case "RemoteChangeDetected":
            let origin = event.modifiedBy.map { deviceNames[$0] ?? $0 }
            if let index = openIndex() {
                rows[index].state = .applied
                rows[index].operation = operation
                rows[index].time = event.time
                rows[index].origin = origin
                rows[index].episodeOpen = false
            } else {
                // Commit without a witnessed item episode (e.g. subscription
                // started mid-apply): still a real, settled change.
                supersedePending()
                insert(Row(time: event.time, folderID: folder, folderLabel: label, path: path,
                           isLocalOrigin: false, operation: operation, state: .applied,
                           origin: origin, episodeOpen: false))
            }

        case "LocalChangeDetected":
            // Deletes travel the same pending→synced journey as modifies:
            // a tombstone needs delivering too.
            supersedePending()
            insert(Row(time: event.time, folderID: folder, folderLabel: label, path: path,
                       isLocalOrigin: true, operation: operation, state: .pending,
                       origin: nil, episodeOpen: false))

        default:
            break
        }
    }

    /// RemoteDownloadProgress: the reporting remote device is actively
    /// fetching these paths — flip matching pending rows to uploading and
    /// refresh their staleness stamp. (~5s cadence; sub-5s transfers never
    /// appear here and jump pending → synced directly.)
    private func markUploading(_ event: SyncthingAPI.ActivityEvent, in rows: inout [Row]) {
        guard let folder = event.folder, let paths = event.downloadingPaths,
              !paths.isEmpty else { return }
        let names = Set(paths)
        for index in rows.indices
        where rows[index].state.isAwaitingDelivery && rows[index].folderID == folder
            && names.contains(rows[index].path) {
            rows[index].state = .uploading
            rows[index].uploadRefreshedAt = now()
        }
    }

    /// No event ends the uploading state — a row not re-confirmed within the
    /// staleness window (transfer finished-but-unconfirmed, or the peer
    /// vanished) goes back to pending; the watermark still owns "synced".
    private func revertStaleUploads(_ rows: inout [Row]) {
        let cutoff = now().addingTimeInterval(-Self.uploadStaleAfter)
        for index in rows.indices where rows[index].state == .uploading {
            if let refreshed = rows[index].uploadRefreshedAt, refreshed >= cutoff { continue }
            rows[index].state = .pending
            rows[index].uploadRefreshedAt = nil
        }
    }

    /// FolderCompletion (per remote device): a full catch-up proves every
    /// awaiting change in the folder was delivered — flip them. "Synced" is
    /// delivered-to-at-least-one, so the first caught-up device flips rows.
    private func applyWatermark(_ event: SyncthingAPI.ActivityEvent, to rows: inout [Row]) {
        guard let folder = event.folder, let device = event.device,
              device != myID,
              event.completion == 100, event.needItems == 0 else { return }
        var flipped = 0
        for index in rows.indices where rows[index].state.isAwaitingDelivery
            && rows[index].folderID == folder {
            rows[index].state = .synced
            rows[index].time = event.time
            rows[index].uploadRefreshedAt = nil
            flipped += 1
        }
        if flipped > 0 {
            Log.monitor.log("activity watermark: \(flipped) rows synced (full catch-up)")
        }
    }

    /// Map seeded disk-change history (oldest→newest from the daemon) to
    /// settled rows, newest first.
    private func seedHistory(_ events: [SyncthingAPI.ActivityEvent]) {
        var seeded: [Row] = []
        for event in events {
            apply(event, to: &seeded)
        }
        commit(seeded)
    }

    private func commit(_ updated: [Row]) {
        let capped = Array(updated.prefix(Self.maxRows))
        if capped != rows { rows = capped }
    }
}
