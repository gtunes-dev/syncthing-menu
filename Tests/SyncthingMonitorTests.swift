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
