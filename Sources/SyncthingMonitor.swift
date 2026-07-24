import Foundation

/// Live daemon-state monitor over Syncthing's events API.
///
/// One long-poll connection (`GET /rest/events`): push semantics — the request
/// parks server-side until a matching event occurs or the server-side timeout
/// lapses (an empty batch), and we immediately re-issue. Idle cost is one
/// trivial localhost round-trip per ~50s; no timers, no busy polling. This is
/// the same mechanism Syncthing's own web GUI uses.
///
/// Tracks two aggregates and reports them on the main thread:
/// - **allDevicesPaused** — every remote device paused (drives the Paused
///   state and the menu's Pause⇄Resume toggle)
/// - **activity** — idle/scanning/syncing across all folders (syncing
///   outranks scanning; drives the icon's Syncing mark and the status texts)
///
/// A filtered event subscription is created on first use and only reports
/// events from that moment on (verified live — there is NO usable history
/// replay for a fresh subscription). So current state is seeded directly:
/// device pause flags from config, folder activity from per-folder status —
/// on connect, on ConfigSaved, and after any stream error. The event cursor
/// is established BEFORE seeding, so a change landing mid-seed is still
/// delivered by the first long-poll — no gap.
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
                                     "ConfigSaved", "FolderErrors"]
    /// Server-side long-poll timeout, seconds (the request timeout is padded
    /// past it — see `SyncthingAPI.events`).
    private static let pollTimeout = 50

    private var task: Task<Void, Never>?

    // Touched only on the main thread (the poll task is @MainActor; awaits
    // run the network work off-main).
    private var remoteDevices = Set<String>()
    private var pausedDevices = Set<String>()
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
        task = Task { @MainActor in await self.run(api: api) }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        remoteDevices = []
        pausedDevices = []
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

    /// Sleeps between failed stream attempts. Injectable seam: tests exercise the
    /// failure/escalation path without real time passing.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    @MainActor
    private func run(api: SyncthingAPI) async {
        var since = 0
        var needsSeed = true
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                if needsSeed {
                    // Cursor first (this also creates the server-side
                    // subscription), then seed: a change landing during the
                    // seed has an id past the cursor and arrives in the loop.
                    since = try await api.events(since: 0, types: Self.eventTypes,
                                                 timeout: 1, limit: 1).last?.id ?? 0
                    try await seed(api)
                    needsSeed = false
                    publish(force: true)
                }
                let events = try await api.events(since: since, types: Self.eventTypes,
                                                  timeout: Self.pollTimeout)
                guard !Task.isCancelled else { return }
                consecutiveFailures = 0
                for event in events {
                    since = max(since, event.id)
                    try await apply(event, api: api)
                }
                publish()
            } catch {
                guard !Task.isCancelled else { return }
                // Daemon unreachable (restarting, mid-upgrade) or a decode
                // hiccup: back off, then rebuild from scratch — event IDs
                // reset when the worker restarts, so keeping a stale `since`
                // could go silent forever. If it stays dark, the endpoint
                // itself is suspect (port/key rotation): escalate to the
                // session and stop — it reconnects us against the endpoint
                // it re-verifies.
                consecutiveFailures += 1
                if consecutiveFailures >= Self.failuresBeforeSuspect {
                    Log.monitor.log("endpoint suspect after \(consecutiveFailures) failures — escalating")
                    onEndpointSuspect?()
                    return
                }
                since = 0
                needsSeed = true
                await retrySleep(2_000_000_000)
            }
        }
    }

    @MainActor
    private func apply(_ event: SyncthingAPI.Event, api: SyncthingAPI) async throws {
        switch event.type {
        case "StateChanged":
            guard let folder = event.folder else { return }
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
        remoteDevices = Set(devices.map(\.deviceID)).subtracting([myID])
        pausedDevices = Set(devices.filter(\.paused).map(\.deviceID)).subtracting([myID])

        var scanning = Set<String>()
        var syncing = Set<String>()
        var names: [String: String] = [:]
        var permission = Set<String>()
        for folder in try await api.folders() {
            names[folder.id] = folder.label.isEmpty ? folder.id : folder.label
            let state = try await api.folderState(id: folder.id)
            if Self.scanningStates.contains(state) {
                scanning.insert(folder.id)
            } else if Self.syncingStates.contains(state) {
                syncing.insert(folder.id)
            }
            if try await api.folderErrors(id: folder.id)
                .contains(where: { Self.isPermissionError($0.error) }) {
                permission.insert(folder.id)
            }
        }
        scanningFolders = scanning
        syncingFolders = syncing
        folderNames = names
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

    @MainActor
    private func publish(force: Bool = false) {
        let activity: SyncActivity = !syncingFolders.isEmpty ? .syncing
                                   : !scanningFolders.isEmpty ? .scanning : .idle
        let snapshot = Snapshot(
            allDevicesPaused: !remoteDevices.isEmpty && remoteDevices.isSubset(of: pausedDevices),
            activity: activity,
            permissionErrorFolders: permissionErrors.map { folderNames[$0] ?? $0 }.sorted())
        guard force || snapshot != published else { return }
        published = snapshot
        Log.monitor.log("allDevicesPaused=\(snapshot.allDevicesPaused) activity=\(String(describing: snapshot.activity), privacy: .public) (scanning: \(self.scanningFolders.isEmpty ? "none" : self.scanningFolders.sorted().joined(separator: ","), privacy: .public); syncing: \(self.syncingFolders.isEmpty ? "none" : self.syncingFolders.sorted().joined(separator: ","), privacy: .public); permissionErrors: \(snapshot.permissionErrorFolders.isEmpty ? "none" : snapshot.permissionErrorFolders.joined(separator: ","), privacy: .public))")
        onChange?(snapshot)
    }
}
