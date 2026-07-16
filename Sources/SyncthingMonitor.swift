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
/// - **syncing** — any folder actively scanning/syncing (drives Syncing)
///
/// A filtered event subscription is created on first use and only reports
/// events from that moment on (verified live — there is NO usable history
/// replay for a fresh subscription). So current state is seeded directly:
/// device pause flags from config, folder activity from per-folder status —
/// on connect, on ConfigSaved, and after any stream error. The event cursor
/// is established BEFORE seeding, so a change landing mid-seed is still
/// delivered by the first long-poll — no gap.
final class SyncthingMonitor {
    struct Snapshot: Equatable {
        var allDevicesPaused = false
        var syncing = false
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

    /// Folder states that count as activity — including the queued "-waiting"
    /// states (folders scan/sync in turn; a waiting folder is part of an active
    /// run). Anything else (idle, error, …) clears the folder.
    private static let activeStates: Set<String> = [
        "scanning", "scan-waiting", "syncing", "sync-waiting", "sync-preparing",
        "cleaning", "clean-waiting",
    ]
    private static let eventTypes = ["StateChanged", "DevicePaused", "DeviceResumed", "ConfigSaved"]
    /// Server-side long-poll timeout, seconds (the request timeout is padded
    /// past it — see `SyncthingAPI.events`).
    private static let pollTimeout = 50

    private var task: Task<Void, Never>?

    // Touched only on the main thread (the poll task is @MainActor; awaits
    // run the network work off-main).
    private var remoteDevices = Set<String>()
    private var pausedDevices = Set<String>()
    private var activeFolders = Set<String>()
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
        activeFolders = []
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
            if let to = event.to, Self.activeStates.contains(to) {
                activeFolders.insert(folder)
            } else {
                activeFolders.remove(folder)
            }
        case "DevicePaused":
            if let device = event.device { pausedDevices.insert(device) }
        case "DeviceResumed":
            if let device = event.device { pausedDevices.remove(device) }
        case "ConfigSaved":
            // Devices/folders may have been added, removed, or (un)paused via
            // config — rebuild both aggregates. Config saves are rare.
            try await seed(api)
        default:
            break
        }
    }

    /// Read current state directly: device pause flags from config, folder
    /// activity from per-folder status.
    @MainActor
    private func seed(_ api: SyncthingAPI) async throws {
        let devices = try await api.devices()
        let myID = try await api.myID()
        remoteDevices = Set(devices.map(\.deviceID)).subtracting([myID])
        pausedDevices = Set(devices.filter(\.paused).map(\.deviceID)).subtracting([myID])

        var active = Set<String>()
        for folder in try await api.folders()
        where Self.activeStates.contains(try await api.folderState(id: folder.id)) {
            active.insert(folder.id)
        }
        activeFolders = active
    }

    @MainActor
    private func publish(force: Bool = false) {
        let snapshot = Snapshot(
            allDevicesPaused: !remoteDevices.isEmpty && remoteDevices.isSubset(of: pausedDevices),
            syncing: !activeFolders.isEmpty)
        guard force || snapshot != published else { return }
        published = snapshot
        Log.monitor.log("allDevicesPaused=\(snapshot.allDevicesPaused) syncing=\(snapshot.syncing) (active: \(self.activeFolders.isEmpty ? "none" : self.activeFolders.sorted().joined(separator: ","), privacy: .public))")
        onChange?(snapshot)
    }
}
