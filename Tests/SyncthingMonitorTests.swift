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
        #expect(snapshots.first == .init(allDevicesPaused: true, syncing: false))
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

        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "syncing"])
        try await expectEventually { snapshots.last?.syncing == true }

        server.pushEvent(type: "StateChanged", data: ["folder": "f1", "to": "idle"])
        try await expectEventually { snapshots.last?.syncing == false }
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
        try await expectEventually { snapshots.last?.syncing == true }

        // Let the scripted failures and the reseed play out: still no escalation,
        // and the snapshot holds.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(suspected == 0)
        #expect(snapshots.last?.syncing == true)
    }
}
