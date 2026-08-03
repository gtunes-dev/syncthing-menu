import Foundation

/// Live daemon-state monitor over Syncthing's events API (`EventStream` —
/// stream mechanics, cursor-first seeding, and error recovery live there).
///
/// Tracks two aggregates and reports them on the main thread:
/// - **allDevicesPaused** — every remote device paused (drives the Paused
///   state and the menu's Pause⇄Resume toggle)
/// - **activity** — idle/scanning/syncing across all folders (syncing
///   outranks scanning; drives the icon's Syncing mark and the status texts)
///
/// Syncing is detected in BOTH directions. Inbound (this device pulling)
/// shows in local folder states via StateChanged. Outbound (peers pulling
/// from us) never touches local folder state — the sending side stays "idle"
/// throughout — so it is detected from FolderCompletion: a **connected,
/// unpaused** remote device reporting an incomplete folder still needs data,
/// which is data in flight. Connectedness gates the signal so an offline
/// stale peer can't pin the aggregate at syncing forever.
///
/// Seeding reads current state directly: device pause flags from config,
/// folder activity from per-folder status, peer connectedness from
/// /rest/system/connections — on connect, on ConfigSaved, and after any
/// stream error. Peer catch-up state is deliberately NOT seeded (that would
/// be a folders × devices request fan-out): it warms up from the first
/// FolderCompletion tick (~2s into any active transfer), and the clear-on-
/// reseed doubles as self-healing — a "behind" flag that survived a stream
/// gap can't stick.
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
        var allDevicesPaused = false
        var activity: SyncActivity = .idle
        /// Display names of folders Syncthing currently can't access for
        /// permission reasons (macOS TCC → EPERM/EACCES) — the signal that
        /// drives the Full Disk Access attention state. Sorted for stability.
        var permissionErrorFolders: [String] = []
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
                                     "DeviceConnected", "DeviceDisconnected",
                                     "FolderCompletion", "ConfigSaved", "FolderErrors"]

    private var stream: EventStream<SyncthingAPI.Event>?

    // Touched only on the main thread (the poll task is @MainActor; awaits
    // run the network work off-main).
    private var myID: String?
    private var remoteDevices = Set<String>()
    private var pausedDevices = Set<String>()
    private var connectedDevices = Set<String>()
    /// Remote device → folders that device still needs data for (its latest
    /// FolderCompletion report was incomplete). The outbound half of syncing;
    /// counted only while the device is connected and unpaused.
    private var behindFolders: [String: Set<String>] = [:]
    /// Locally paused folders. A paused folder is not RUNNING: it can't scan,
    /// sync, or send, and its per-folder endpoints 404 ("folder is paused" —
    /// verified live 2026-08-03), so the seed must not read them and its
    /// events must not count. Pause/unpause is a config change → ConfigSaved
    /// → reseed keeps this current.
    private var pausedFolders = Set<String>()
    private var scanningFolders = Set<String>()
    private var syncingFolders = Set<String>()
    /// Folder ids whose current errors include a permission failure.
    private var permissionErrors = Set<String>()
    /// Folder id → display name (label, falling back to the id).
    private var folderNames: [String: String] = [:]
    private var published: Snapshot?

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
                try await self.seed(api)
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
        self.stream = stream
        stream.start()
    }

    func disconnect() {
        stream?.stop()
        stream = nil
        myID = nil
        remoteDevices = []
        pausedDevices = []
        connectedDevices = []
        behindFolders = [:]
        pausedFolders = []
        scanningFolders = []
        syncingFolders = []
        permissionErrors = []
        folderNames = [:]
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
            guard let folder = event.folder,
                  !pausedFolders.contains(folder) else { return }
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
        case "DevicePaused":
            if let device = event.device { pausedDevices.insert(device) }
        case "DeviceResumed":
            if let device = event.device { pausedDevices.remove(device) }
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
                  let folder = event.folder,
                  !pausedFolders.contains(folder) else { return }
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
            // config — rebuild both aggregates. Config saves are rare.
            try await seed(api)
        default:
            break
        }
    }

    /// Read current state directly: device pause flags from config, folder
    /// activity from per-folder status, folder health from per-folder errors.
    @MainActor
    private func seed(_ api: SyncthingAPI) async throws {
        let devices = try await api.devices()
        let myID = try await api.myID()
        self.myID = myID
        remoteDevices = Set(devices.map(\.deviceID)).subtracting([myID])
        pausedDevices = Set(devices.filter(\.paused).map(\.deviceID)).subtracting([myID])
        connectedDevices = try await api.connectedDevices()
        // Peer catch-up is event-warmed, not seeded — and clearing here is the
        // self-heal for any behind flag orphaned by a stream gap (see class doc).
        behindFolders = [:]

        var scanning = Set<String>()
        var syncing = Set<String>()
        var names: [String: String] = [:]
        var paused = Set<String>()
        var permission = Set<String>()
        for folder in try await api.folders() {
            names[folder.id] = folder.label.isEmpty ? folder.id : folder.label
            // A paused folder is not running: it has no activity, its errors
            // are moot (and unreadable — the endpoint 404s), so skip its
            // per-folder reads entirely. One paused folder must never take
            // the whole seed down (that froze the monitor in an escalation
            // loop — found live 2026-08-03).
            if folder.paused {
                paused.insert(folder.id)
                continue
            }
            // Per-folder reads are tolerant for the same reason: a folder
            // that is configured but not running (stopped on a path error,
            // mid-restart) also 404s. Unreadable = treat as inactive and
            // error-free rather than killing the seed; the next reseed or
            // event corrects it.
            if let state = try? await api.folderState(id: folder.id) {
                if Self.scanningStates.contains(state) {
                    scanning.insert(folder.id)
                } else if Self.syncingStates.contains(state) {
                    syncing.insert(folder.id)
                }
            }
            if let errors = try? await api.folderErrors(id: folder.id),
               errors.contains(where: { Self.isPermissionError($0.error) }) {
                permission.insert(folder.id)
            }
        }
        scanningFolders = scanning
        syncingFolders = syncing
        folderNames = names
        pausedFolders = paused
        permissionErrors = permission
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
                && !pausedDevices.contains(device) ? device : nil
        }.sorted()
    }

    @MainActor
    private func publish(force: Bool = false) {
        let outbound = outboundDevices
        let activity: SyncActivity = !syncingFolders.isEmpty || !outbound.isEmpty ? .syncing
                                   : !scanningFolders.isEmpty ? .scanning : .idle
        let snapshot = Snapshot(
            allDevicesPaused: !remoteDevices.isEmpty && remoteDevices.isSubset(of: pausedDevices),
            activity: activity,
            permissionErrorFolders: permissionErrors.map { folderNames[$0] ?? $0 }.sorted())
        guard force || snapshot != published else { return }
        published = snapshot
        Log.monitor.log("allDevicesPaused=\(snapshot.allDevicesPaused) activity=\(String(describing: snapshot.activity), privacy: .public) (scanning: \(self.scanningFolders.isEmpty ? "none" : self.scanningFolders.sorted().joined(separator: ","), privacy: .public); syncing: \(self.syncingFolders.isEmpty ? "none" : self.syncingFolders.sorted().joined(separator: ","), privacy: .public); outbound: \(outbound.isEmpty ? "none" : outbound.map { String($0.prefix(7)) }.joined(separator: ","), privacy: .public); permissionErrors: \(snapshot.permissionErrorFolders.isEmpty ? "none" : snapshot.permissionErrorFolders.joined(separator: ","), privacy: .public))")
        onChange?(snapshot)
    }
}
