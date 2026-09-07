import Foundation

/// Live daemon-state monitor over Syncthing's events API (`EventStream` —
/// stream mechanics, cursor-first seeding, and error recovery live there).
///
/// Reports, on the main thread, one `Snapshot` of daemon-side state:
/// - **activity** — idle/scanning/syncing across all folders (syncing
///   outranks scanning; drives the icon's Syncing mark and the status texts)
/// - **folders / devices** — the configured lists with the per-object state
///   the menu renders (paused, permission-blocked). Everything derived from
///   them (all devices paused → the All Paused state and the Pause All ⇄
///   Resume All title; the Settings FDA alert) is computed ON the snapshot,
///   so every consumer reads one source of truth and nothing is re-fetched
///   on menu open.
///
/// Syncing is detected in BOTH directions. Inbound (this device pulling)
/// shows in local folder states via StateChanged. Outbound (peers pulling
/// from us) never touches local folder state — the sending side stays "idle"
/// throughout — so it is detected from FolderCompletion: a **connected,
/// unpaused** remote device reporting an incomplete folder still needs data,
/// which is data in flight. Connectedness gates the signal so an offline
/// stale peer can't pin the aggregate at syncing forever.
///
/// Seeding reads current state directly: the folder and device lists (with
/// their pause flags) from config, folder activity from per-folder status,
/// peer connectedness from /rest/system/connections — on connect, on
/// ConfigSaved, and after any stream error. Between reseeds the lists are
/// kept current in place by events: Device/FolderPaused/Resumed flip the
/// flag the moment the daemon reports it (a menu Pause click shows on its
/// row before the ConfigSaved reseed that follows). Peer catch-up state is
/// deliberately NOT seeded (that would be a folders × devices request
/// fan-out): it warms up from the first FolderCompletion tick (~2s into any
/// active transfer), and clearing it on a connect/stream-error reseed is the
/// self-heal — a "behind" flag that survived a stream gap can't stick. A
/// ConfigSaved reseed keeps it: no gap happened, and a menu verb must not
/// blank the outbound-syncing display.
/// Aggregate folder activity, coarsened from Syncthing's per-folder states.
/// Three values because they mean different things to the user: scanning is
/// local housekeeping (hashing, no network), syncing is data actually moving
/// between devices. Syncing outranks scanning in every aggregate — transfer
/// is the more consequential fact, so the display never understates.
enum SyncActivity: Equatable {
    case idle
    case scanning
    case syncing
}

/// Ordered by display priority — syncing > scanning > idle — so aggregation
/// and display smoothing can compare levels instead of re-encoding the ladder.
extension SyncActivity: Comparable {
    private var rank: Int {
        switch self {
        case .idle: 0
        case .scanning: 1
        case .syncing: 2
        }
    }

    static func < (lhs: SyncActivity, rhs: SyncActivity) -> Bool {
        lhs.rank < rhs.rank
    }
}

final class SyncthingMonitor {
    struct Snapshot: Equatable {
        /// One configured folder, with the two per-folder states the menu
        /// marks. `attention` = Syncthing can't access it for permission
        /// reasons (macOS TCC → EPERM/EACCES) — the Full Disk Access signal.
        /// Keyed by `id`; `name` is for reading (labels may be duplicated).
        struct Folder: Equatable {
            let id: String
            let name: String
            let path: String
            let paused: Bool
            let attention: Bool
        }

        /// One REMOTE device (this device is filtered out), with its pause
        /// flag — per-device config state in the daemon.
        struct Device: Equatable {
            let id: String
            let name: String
            let paused: Bool
        }

        var activity: SyncActivity = .idle
        /// Config order, as the daemon lists them.
        var folders: [Folder] = []
        var devices: [Device] = []

        /// Every remote device paused — what the daemon's unscoped pause call
        /// produces (indistinguishable, in the daemon too, from pausing each
        /// by hand). Drives the All Paused state and Pause All ⇄ Resume All.
        /// False with no remote devices: nothing is paused then.
        var allDevicesPaused: Bool { !devices.isEmpty && devices.allSatisfy(\.paused) }
        var anyFolderPaused: Bool { folders.contains { $0.paused } }
        var anyDevicePaused: Bool { devices.contains { $0.paused } }
        var folderAttention: Bool { folders.contains { $0.attention } }
        /// Display names of the permission-blocked folders, sorted for
        /// stability — what Settings' FDA section lists.
        var permissionErrorFolders: [String] { folders.filter(\.attention).map(\.name).sorted() }
    }

    /// Called on the main thread once after the initial seed and on every
    /// snapshot change thereafter.
    var onChange: ((Snapshot) -> Void)?

    /// Called on the main thread when the endpoint has stopped answering for
    /// several consecutive attempts while the daemon supposedly runs. The monitor
    /// is the session's canonical health probe (it's the always-on long-poll):
    /// rather than retrying a possibly-dead endpoint forever, it escalates and
    /// stops; the session re-discovers the endpoint and reconnects the monitor
    /// when it verifies (see `DaemonSession.endpointSuspect`).
    var onEndpointSuspect: (() -> Void)?

    /// Folder states that count as activity, split into the two families the
    /// aggregate distinguishes — including the queued "-waiting" states
    /// (folders scan/sync in turn; a waiting folder is part of an active run).
    /// Cleaning is post-pull cleanup, so it belongs to the sync episode.
    /// Anything else (idle, error, …) clears the folder.
    private static let scanningStates: Set<String> = ["scanning", "scan-waiting"]
    private static let syncingStates: Set<String> = [
        "syncing", "sync-waiting", "sync-preparing", "cleaning", "clean-waiting",
    ]
    private static let eventTypes = ["StateChanged", "DevicePaused", "DeviceResumed",
                                     "FolderPaused", "FolderResumed",
                                     "DeviceConnected", "DeviceDisconnected",
                                     "FolderCompletion", "ConfigSaved", "FolderErrors"]

    private var stream: EventStream<SyncthingAPI.Event>?

    // Touched only on the main thread (the poll task is @MainActor; awaits
    // run the network work off-main).
    private var myID: String?
    /// The configured lists, as the snapshot publishes them — ONE
    /// representation of each object's pause flag: read from config at seed,
    /// flipped in place by the pause/resume events between reseeds.
    private struct FolderRecord {
        let id: String
        let name: String
        let path: String
        var paused: Bool
    }
    private struct DeviceRecord {
        let id: String
        let name: String
        var paused: Bool
    }
    private var folders: [FolderRecord] = []
    /// Remote devices only (this device is filtered out at seed).
    private var devices: [DeviceRecord] = []
    /// The folders that were running as of the last seed — what a
    /// `.configChange` seed compares against to find folders that STARTED
    /// running. Kept apart from the live records because a FolderResumed
    /// event may flip a record before the ConfigSaved that follows it, and
    /// that folder still needs its first read.
    private var seededRunning = Set<String>()
    private var connectedDevices = Set<String>()
    /// Remote device → folders that device still needs data for (its latest
    /// FolderCompletion report was incomplete). The outbound half of syncing;
    /// counted only while the device is connected and unpaused.
    private var behindFolders: [String: Set<String>] = [:]
    private var scanningFolders = Set<String>()
    private var syncingFolders = Set<String>()
    /// Folder ids whose current errors include a permission failure.
    private var permissionErrors = Set<String>()
    private var published: Snapshot?

    /// A paused folder is not RUNNING: it can't scan, sync, or send, and its
    /// per-folder endpoints 404 ("folder is paused" — verified live
    /// 2026-08-03), so the seed must not read it and its events must not
    /// count.
    private func isPaused(folder id: String) -> Bool {
        folders.contains { $0.id == id && $0.paused }
    }

    private func isPaused(device id: String) -> Bool {
        devices.contains { $0.id == id && $0.paused }
    }

    /// A folder that is no longer running (paused, removed) leaves every
    /// live set: nothing about it is in flight, and no later event would
    /// clear it (a paused folder's completion reports are guarded out).
    private func forget(folder id: String) {
        scanningFolders.remove(id)
        syncingFolders.remove(id)
        for device in behindFolders.keys { behindFolders[device]?.remove(id) }
    }

    /// Flip a folder's / device's pause flag in place (a Paused/Resumed
    /// event). Unknown ids are ignored: an object added and paused in one
    /// config save is picked up by that save's reseed.
    private func setPaused(folder id: String, _ paused: Bool) {
        if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].paused = paused }
    }

    private func setPaused(device id: String, _ paused: Bool) {
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].paused = paused }
    }

    /// Start monitoring the daemon behind `api` (a session-verified endpoint).
    /// Replaces any prior connection — safe to call on every session publish.
    func connect(api: SyncthingAPI) {
        disconnect()
        let stream = EventStream<SyncthingAPI.Event>(
            label: "monitor",
            fetch: { try await api.events(since: $0, types: Self.eventTypes,
                                          timeout: $1, limit: $2) },
            seed: { [weak self] in
                guard let self else { return }
                try await self.seed(api, scope: .full)
                self.publish(force: true)
            },
            handle: { [weak self] events in
                guard let self else { return }
                for event in events {
                    try await self.apply(event, api: api)
                }
                self.publish()
            },
            failuresBeforeEscalation: Self.failuresBeforeSuspect,
            onEscalate: { [weak self] in self?.onEndpointSuspect?() })
        stream.retrySleep = retrySleep
        // The full seed is THE self-heal for anything a lost event could
        // leave stuck (a folder's scanning flag, a peer's catch-up entry) —
        // the ConfigSaved reseed is deliberately narrow (`SeedScope`), so a
        // ring-overflow gap must trigger a full one itself.
        stream.reseedAfterGap = true
        self.stream = stream
        stream.start()
    }

    func disconnect() {
        stream?.stop()
        stream = nil
        myID = nil
        folders = []
        devices = []
        seededRunning = []
        connectedDevices = []
        behindFolders = [:]
        scanningFolders = []
        syncingFolders = []
        permissionErrors = []
        published = nil
    }

    /// Consecutive stream failures tolerated (with a 2s pause each) before the
    /// endpoint is reported suspect. Three keeps a routine worker restart (a
    /// couple of seconds, e.g. mid-upgrade) below the escalation threshold.
    private static let failuresBeforeSuspect = 3

    /// Sleeps between failed stream attempts (handed to the stream at connect).
    /// Injectable seam: tests exercise the failure/escalation path without
    /// real time passing.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    @MainActor
    private func apply(_ event: SyncthingAPI.Event, api: SyncthingAPI) async throws {
        switch event.type {
        case "StateChanged":
            // Ignore events for paused folders: a stale activity event racing
            // the pause would insert a folder that never emits again — stuck.
            guard let folder = event.folder, !isPaused(folder: folder) else { return }
            if let to = event.to, Self.scanningStates.contains(to) {
                scanningFolders.insert(folder)
                syncingFolders.remove(folder)
            } else if let to = event.to, Self.syncingStates.contains(to) {
                syncingFolders.insert(folder)
                scanningFolders.remove(folder)
            } else {
                scanningFolders.remove(folder)
                syncingFolders.remove(folder)
                // A completed scan/pull may have cleared this folder's errors,
                // and FolderErrors only fires when errors OCCUR — recovery is
                // visible only by re-reading. Query just the flagged folders;
                // keep the flag on a transient read failure.
                if permissionErrors.contains(folder),
                   let errors = try? await api.folderErrors(id: folder),
                   !errors.contains(where: { Self.isPermissionError($0.error) }) {
                    permissionErrors.remove(folder)
                }
            }
        case "DevicePaused", "DeviceResumed":
            if let device = event.device { setPaused(device: device, event.type == "DevicePaused") }
        case "FolderPaused", "FolderResumed":
            // The flag lands the moment the daemon reports it; the
            // ConfigSaved that follows re-reads everything anyway. A paused
            // folder is not running: it leaves the activity sets and every
            // peer's catch-up set at once — no later event would remove it
            // (its FolderCompletion reports are guarded out), and "a paused
            // folder can't be sending" must hold for stored entries too.
            guard let folder = event.folder else { return }
            let paused = event.type == "FolderPaused"
            setPaused(folder: folder, paused)
            if paused { forget(folder: folder) }
        case "DeviceConnected":
            if let device = event.device { connectedDevices.insert(device) }
        case "DeviceDisconnected":
            if let device = event.device {
                connectedDevices.remove(device)
                // A disconnected peer can't be receiving data, and its
                // completion reports die with the connection; Syncthing
                // recomputes and re-reports completion on reconnect.
                behindFolders[device] = nil
            }
        case "FolderCompletion":
            // The remote device's catch-up state for one folder, recomputed
            // whenever either side's index moves. Replace, don't accumulate:
            // each event is that (device, folder) pair's current truth.
            // A locally paused folder can't be sending — a behind peer on it
            // is not data in flight.
            guard let device = event.device, device != myID,
                  let folder = event.folder, !isPaused(folder: folder) else { return }
            if Self.isBehind(event) {
                behindFolders[device, default: []].insert(folder)
            } else {
                behindFolders[device]?.remove(folder)
            }
        case "FolderErrors":
            // Carries the folder's CURRENT error list — replace, don't merge.
            guard let folder = event.folder else { return }
            if let errors = event.errors, errors.contains(where: { Self.isPermissionError($0.error) }) {
                permissionErrors.insert(folder)
            } else {
                permissionErrors.remove(folder)
            }
        case "ConfigSaved":
            // Devices/folders may have been added, removed, or (un)paused via
            // config — re-read the lists; per-folder state only for folders
            // that just started running. Peer catch-up survives: no stream
            // gap happened (see the class doc).
            try await seed(api, scope: .configChange)
        default:
            break
        }
    }

    /// What a seed re-reads. `.full` (connect, stream error): everything —
    /// the lists, and every running folder's state and errors, with peer
    /// catch-up cleared (the self-heal — see the class doc). `.configChange`
    /// (ConfigSaved): the lists, and per-folder state ONLY for folders that
    /// just started running — a config save can't change the activity or
    /// errors of a folder that was already running (its events keep those
    /// current), and every menu Pause/Resume click is a config save, so this
    /// keeps a click at a handful of requests instead of 2 × folders.
    private enum SeedScope { case full, configChange }

    /// Read current state directly: the folder and device lists (pause flags
    /// included) from config, folder activity from per-folder status, folder
    /// health from per-folder errors — see `SeedScope` for how much.
    @MainActor
    private func seed(_ api: SyncthingAPI, scope: SeedScope) async throws {
        let configDevices = try await api.devices()
        let myID = try await api.myID()
        self.myID = myID
        devices = configDevices.filter { $0.deviceID != myID }.map {
            DeviceRecord(id: $0.deviceID, name: $0.displayName, paused: $0.paused)
        }
        connectedDevices = try await api.connectedDevices()

        let configFolders = try await api.folders()
        let running = Set(configFolders.filter { !$0.paused }.map(\.id))
        let wasRunning: Set<String>
        switch scope {
        case .full:
            // Peer catch-up is event-warmed, not seeded; the live sets are
            // rebuilt from the reads below.
            behindFolders = [:]
            scanningFolders = []
            syncingFolders = []
            permissionErrors = []
            wasRunning = []
        case .configChange:
            // The live sets carry over for folders that still run; a folder
            // paused, removed, or un-shared by the change leaves every set —
            // it gets no further events (a paused folder's completion
            // reports are guarded out), so a surviving entry would pin
            // "syncing" until the peer disconnects.
            wasRunning = seededRunning
            scanningFolders.formIntersection(running)
            syncingFolders.formIntersection(running)
            permissionErrors.formIntersection(running)
            // Per peer: the running folders still SHARED with it. A peer
            // un-shared from a folder gets no further completion reports for
            // it either (the daemon reports only to current sharers), so
            // pruning by folder alone would pin that entry.
            behindFolders = Dictionary(uniqueKeysWithValues: behindFolders.map { device, behind in
                (device, behind.filter { id in
                    running.contains(id) && configFolders.contains { folder in
                        folder.id == id && (folder.devices?.contains { $0.deviceID == device } ?? true)
                    }
                })
            })
        }
        folders = configFolders.map {
            FolderRecord(id: $0.id, name: $0.displayName, path: $0.path, paused: $0.paused)
        }
        seededRunning = running

        // A paused folder is not running: it has no activity, its errors are
        // moot (and unreadable — the endpoint 404s), so it gets no per-folder
        // reads. One paused folder must never take the whole seed down (that
        // froze the monitor in an escalation loop — found live 2026-08-03).
        for folder in configFolders where running.contains(folder.id) && !wasRunning.contains(folder.id) {
            // Per-folder reads are tolerant for the same reason: a folder
            // that is configured but not running (stopped on a path error,
            // mid-restart) also 404s. Unreadable = treat as inactive and
            // error-free rather than killing the seed; the next reseed or
            // event corrects it.
            scanningFolders.remove(folder.id)
            syncingFolders.remove(folder.id)
            if let state = try? await api.folderState(id: folder.id) {
                if Self.scanningStates.contains(state) {
                    scanningFolders.insert(folder.id)
                } else if Self.syncingStates.contains(state) {
                    syncingFolders.insert(folder.id)
                }
            }
            if let errors = try? await api.folderErrors(id: folder.id),
               errors.contains(where: { Self.isPermissionError($0.error) }) {
                permissionErrors.insert(folder.id)
            } else {
                permissionErrors.remove(folder.id)
            }
        }
    }

    /// The error texts macOS permission failures produce: a TCC denial surfaces
    /// as EPERM ("operation not permitted") or EACCES ("permission denied") from
    /// the filesystem, embedded in Syncthing's per-path error strings.
    private static func isPermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("operation not permitted")
            || lowered.contains("permission denied")
    }

    /// This FolderCompletion report says the remote device still needs data.
    /// `completion` alone isn't sufficient: deletes-only changes can report
    /// completion 100 with needDeletes > 0.
    private static func isBehind(_ event: SyncthingAPI.Event) -> Bool {
        (event.completion ?? 100) < 100 || (event.needItems ?? 0) > 0
            || (event.needDeletes ?? 0) > 0
    }

    /// The devices whose behind-ness counts as outbound syncing right now:
    /// behind on ≥1 folder, connected, and not paused.
    private var outboundDevices: [String] {
        behindFolders.compactMap { device, folders in
            !folders.isEmpty && connectedDevices.contains(device)
                && !isPaused(device: device) ? device : nil
        }.sorted()
    }

    @MainActor
    private func publish(force: Bool = false) {
        let outbound = outboundDevices
        let activity: SyncActivity = !syncingFolders.isEmpty || !outbound.isEmpty ? .syncing
                                   : !scanningFolders.isEmpty ? .scanning : .idle
        let snapshot = Snapshot(
            activity: activity,
            folders: folders.map {
                Snapshot.Folder(id: $0.id, name: $0.name, path: $0.path, paused: $0.paused,
                                attention: permissionErrors.contains($0.id))
            },
            devices: devices.map { Snapshot.Device(id: $0.id, name: $0.name, paused: $0.paused) })
        guard force || snapshot != published else { return }
        published = snapshot
        Log.monitor.log("allDevicesPaused=\(snapshot.allDevicesPaused) activity=\(String(describing: snapshot.activity), privacy: .public) (scanning: \(self.scanningFolders.isEmpty ? "none" : self.scanningFolders.sorted().joined(separator: ","), privacy: .public); syncing: \(self.syncingFolders.isEmpty ? "none" : self.syncingFolders.sorted().joined(separator: ","), privacy: .public); outbound: \(outbound.isEmpty ? "none" : outbound.map(SyncthingAPI.Device.shortID).joined(separator: ","), privacy: .public); permissionErrors: \(snapshot.permissionErrorFolders.isEmpty ? "none" : snapshot.permissionErrorFolders.joined(separator: ","), privacy: .public))")
        onChange?(snapshot)
    }
}
