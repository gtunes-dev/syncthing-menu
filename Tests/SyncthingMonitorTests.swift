import Foundation
import Testing
@testable import SyncthingMenu

/// Scenario tests for the live-state monitor: seeding, event-driven snapshots,
/// ConfigSaved reseeds, and the health-probe escalation contract it provides to
/// the session layer.
@MainActor
struct SyncthingMonitorTests {

    private func api(for server: FakeSyncthingServer, key: String = "test-key") -> SyncthingAPI {
        SyncthingAPI(baseURL: URL(string: server.baseURL)!, apiKey: key)
    }

    /// Connect seeds real state directly (the event subscription has no history):
    /// the local device is filtered out, pre-existing pause flags are seen.
    @Test func seedPublishesCurrentStateAndFiltersSelf() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: true)]
        server.folders = [.init(id: "f1")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        // The only remote device (A) is paused; SELF must not count.
        #expect(snapshots.first == .init(allDevicesPaused: true, activity: .idle))
    }

    /// StateChanged events flip folder activity — including back to idle.
    @Test func stateChangedEventsDriveSyncing() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.folders = [.init(id: "f1")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        // Scanning and syncing are distinct aggregates; syncing outranks
        // scanning when both families are active across folders.
        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "scanning"])
        try await expectEventually { snapshots.last?.activity == .scanning }

        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "syncing"])
        try await expectEventually { snapshots.last?.activity == .syncing }

        server.pushEvent(type: "StateChanged", data: ["folder": "f2", "to": "scanning"])
        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "idle"])
        try await expectEventually { snapshots.last?.activity == .scanning }

        server.pushEvent(type: "StateChanged", data: ["folder": "f2", "to": "idle"])
        try await expectEventually { snapshots.last?.activity == .idle }
    }

    /// DevicePaused/DeviceResumed drive the all-devices-paused aggregate.
    @Test func devicePauseEventsDriveAllDevicesPaused() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false)]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }
        #expect(snapshots.first?.allDevicesPaused == false)

        server.pushEvent(type: "DevicePaused", data: ["device": "A"])
        try await expectEventually { snapshots.last?.allDevicesPaused == true }

        server.pushEvent(type: "DeviceResumed", data: ["device": "A"])
        try await expectEventually { snapshots.last?.allDevicesPaused == false }
    }

    /// ConfigSaved rebuilds both aggregates from scratch (devices/folders may have
    /// been added, removed, or (un)paused via config).
    @Test func configSavedReseeds() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false)]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: true)]
        server.pushEvent(type: "ConfigSaved")
        try await expectEventually { snapshots.last?.allDevicesPaused == true }
    }

    /// Seeding reads each folder's current errors: a permission failure present
    /// at connect is surfaced immediately (by display name), while ordinary
    /// errors (disk full, …) never raise the FDA signal.
    @Test func seedFlagsPermissionErrorsOnly() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.folders = [
            .init(id: "f1", label: "Documents",
                  errors: [(path: "/Users/x/Documents/a", error: "scanning: open: operation not permitted")]),
            .init(id: "f2", label: "Cabinet",
                  errors: [(path: "/Users/x/Cabinet/b", error: "no space left on device")]),
            .init(id: "f3", label: "Photos"),
        ]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }
        #expect(snapshots.first?.permissionErrorFolders == ["Documents"])
    }

    /// A FolderErrors event carries the folder's CURRENT error list: permission
    /// errors raise the signal, and a later list without them clears it.
    @Test func folderErrorsEventsRaiseAndReplace() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.folders = [.init(id: "f1", label: "Documents")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }
        #expect(snapshots.first?.permissionErrorFolders == [])

        server.pushEvent(type: "FolderErrors", data: [
            "folder": "f1",
            "errors": [["path": "/Users/x/Documents/a", "error": "pulling: permission denied"]],
        ])
        try await expectEventually { snapshots.last?.permissionErrorFolders == ["Documents"] }

        server.pushEvent(type: "FolderErrors", data: [
            "folder": "f1",
            "errors": [["path": "/Users/x/Documents/b", "error": "connection reset"]],
        ])
        try await expectEventually { snapshots.last?.permissionErrorFolders == [] }
    }

    /// Recovery is silent (FolderErrors only fires when errors OCCUR): when a
    /// flagged folder finishes a scan/pull cleanly, the monitor re-reads its
    /// errors and clears the signal.
    @Test func recoveryClearsOnCleanScan() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.folders = [.init(id: "f1", label: "Documents",
                                errors: [(path: "/a", error: "operation not permitted")])]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { snapshots.last?.permissionErrorFolders == ["Documents"] }

        // FDA granted: the next scan succeeds — errors gone, folder lands idle.
        server.folders = [.init(id: "f1", label: "Documents")]
        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "scanning"])
        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "idle"])
        try await expectEventually { snapshots.last?.permissionErrorFolders == [] }
    }

    /// Outbound transfer: the sending side's folder state stays idle, so
    /// syncing is detected from FolderCompletion — a connected remote peer
    /// reporting an incomplete folder is data in flight; full catch-up ends
    /// it. Connectedness comes from the seed (no DeviceConnected event fires
    /// for an already-connected peer).
    @Test func behindConnectedPeerDrivesSyncing() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false, connected: true)]
        server.folders = [.init(id: "f1")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }
        #expect(snapshots.first?.activity == .idle)

        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A",
            "completion": 42.5, "needItems": 3, "needDeletes": 0,
        ])
        try await expectEventually { snapshots.last?.activity == .syncing }

        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A",
            "completion": 100, "needItems": 0, "needDeletes": 0,
        ])
        try await expectEventually { snapshots.last?.activity == .idle }
    }

    /// Deletes-only outbound changes: completion can report 100 while
    /// needDeletes > 0 — the tombstones still need delivering.
    @Test func needDeletesAloneCountsAsBehind() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false, connected: true)]
        server.folders = [.init(id: "f1")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A",
            "completion": 100, "needItems": 0, "needDeletes": 2,
        ])
        try await expectEventually { snapshots.last?.activity == .syncing }

        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A",
            "completion": 100, "needItems": 0, "needDeletes": 0,
        ])
        try await expectEventually { snapshots.last?.activity == .idle }
    }

    /// Only peers that can actually receive data count: disconnect drops the
    /// behind flag (fresh reports arrive on reconnect), pause filters it
    /// while keeping it (resume restores the signal without a new report).
    /// A FolderCompletion for the local device never counts.
    @Test func onlyConnectedUnpausedPeersDriveOutbound() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        // SELF "connected" so that, were the myID guard missing, its report
        // below would keep the aggregate syncing past A's disconnect.
        server.devices = [.init(deviceID: "SELF", paused: false, connected: true),
                          .init(deviceID: "A", paused: false, connected: true)]
        server.folders = [.init(id: "f1")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        // Self-reports are ignored outright.
        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "SELF", "completion": 10,
        ])
        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A", "completion": 10,
        ])
        try await expectEventually { snapshots.last?.activity == .syncing }

        // Connect/disconnect events carry the device id as "id" (not
        // "device" like the pause events) — the pushes model the real shape.
        server.pushEvent(type: "DeviceDisconnected", data: ["id": "A", "error": "EOF"])
        try await expectEventually { snapshots.last?.activity == .idle }

        // Reconnect alone doesn't resurrect the dropped flag…
        server.pushEvent(type: "DeviceConnected", data: ["id": "A"])
        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A", "completion": 55,
        ])
        try await expectEventually { snapshots.last?.activity == .syncing }

        // …while pause merely filters: the peer still needs the data, so
        // resume restores the signal without a fresh report.
        server.pushEvent(type: "DevicePaused", data: ["device": "A"])
        try await expectEventually { snapshots.last?.activity == .idle }
        server.pushEvent(type: "DeviceResumed", data: ["device": "A"])
        try await expectEventually { snapshots.last?.activity == .syncing }
    }

    /// Outbound syncing takes the same rung as inbound on the ladder: it
    /// outranks a concurrent scan, and the aggregate falls back to scanning
    /// (not idle) when the peer catches up mid-scan.
    @Test func outboundOutranksScanning() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false, connected: true)]
        server.folders = [.init(id: "f1"), .init(id: "f2")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        server.pushEvent(type: "StateChanged", data: ["folder": "f2", "to": "scanning"])
        try await expectEventually { snapshots.last?.activity == .scanning }

        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A", "completion": 10,
        ])
        try await expectEventually { snapshots.last?.activity == .syncing }

        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A", "completion": 100,
        ])
        try await expectEventually { snapshots.last?.activity == .scanning }
    }

    /// THE PAUSED-FOLDER REGRESSION (found live 2026-08-03): /rest/folder/errors
    /// returns 404 for a paused folder, which killed the whole seed — the
    /// monitor never published and looped on escalation while the endpoint was
    /// healthy. A paused folder must not break seeding, must never escalate,
    /// and contributes no activity or permission errors.
    @Test func pausedFolderDoesNotBreakSeeding() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false, connected: true)]
        server.folders = [
            .init(id: "f1", label: "Paused", state: "syncing", paused: true,
                  errors: [(path: "/a", error: "operation not permitted")]),
            .init(id: "f2", label: "Active"),
        ]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        monitor.retrySleep = fastSleep
        var suspected = 0
        monitor.onEndpointSuspect = { suspected += 1 }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        // Seed succeeded despite the paused folder's 404; its scripted
        // "syncing" state and permission error are ignored — not running.
        #expect(snapshots.first == .init(allDevicesPaused: false, activity: .idle))
        #expect(suspected == 0)
    }

    /// A locally paused folder can't be sending: neither its (stale)
    /// StateChanged events nor a behind peer on it may drive activity.
    /// Unpausing arrives as a config change and re-includes it.
    @Test func pausedFolderEventsDoNotCount() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false, connected: true)]
        server.folders = [.init(id: "f1", paused: true), .init(id: "f2")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "scanning"])
        server.pushEvent(type: "FolderCompletion", data: [
            "folder": "f1", "device": "A", "completion": 10,
        ])
        // Marker on the active folder proves both events were processed.
        server.pushEvent(type: "StateChanged", data: ["folder": "f2", "to": "scanning"])
        try await expectEventually { snapshots.last?.activity == .scanning }
        #expect(!snapshots.contains { $0.activity == .syncing })

        // Unpause (a config change): the folder's activity counts again.
        server.folders = [.init(id: "f1", state: "syncing"), .init(id: "f2")]
        server.pushEvent(type: "ConfigSaved")
        try await expectEventually { snapshots.last?.activity == .syncing }
    }

    /// The health-probe contract: a persistently dark endpoint escalates exactly
    /// once (after the tolerated failures) and the monitor stops on its own — the
    /// session owns recovery from there.
    @Test func persistentFailureEscalatesOnceAndStops() async throws {
        // A real port with nothing listening: start a listener, then close it.
        let server = FakeSyncthingServer()
        try server.start()
        let deadAPI = api(for: server)
        server.stop()

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        monitor.retrySleep = fastSleep
        var suspected = 0
        monitor.onEndpointSuspect = { suspected += 1 }
        var snapshots = 0
        monitor.onChange = { _ in snapshots += 1 }

        monitor.connect(api: deadAPI)
        try await expectEventually { suspected == 1 }

        // Escalation is terminal for this connection: no repeats, no snapshots.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(suspected == 1)
        #expect(snapshots == 0)
    }

    /// Failures below the threshold (a routine worker restart) recover in place:
    /// reseed, keep publishing, never escalate.
    @Test func transientFailuresRecoverWithoutEscalating() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.folders = [.init(id: "f1")]

        let monitor = SyncthingMonitor()
        defer { monitor.disconnect() }
        monitor.retrySleep = fastSleep
        var suspected = 0
        monitor.onEndpointSuspect = { suspected += 1 }
        var snapshots: [SyncthingMonitor.Snapshot] = []
        monitor.onChange = { snapshots.append($0) }

        monitor.connect(api: api(for: server))
        try await expectEventually { !snapshots.isEmpty }

        // Two failures — one below the threshold of three. Ground truth changes
        // too (folder now syncing), so the post-recovery reseed agrees with the
        // pushed event.
        server.failNextRequests = 2
        server.folders = [.init(id: "f1", state: "syncing")]
        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "syncing"])
        try await expectEventually { snapshots.last?.activity == .syncing }

        // Let the scripted failures and the reseed play out: still no escalation,
        // and the snapshot holds.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(suspected == 0)
        #expect(snapshots.last?.activity == .syncing)
    }
}
