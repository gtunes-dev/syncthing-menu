import Foundation
import Testing
@testable import SyncthingMenu

/// Scenario tests for the session layer: discovery → verify → enforce → publish,
/// and every reconciliation path (rotation, move, blip, supersession) against a
/// real localhost endpoint (`FakeSyncthingServer`).
@MainActor
struct DaemonSessionTests {

    private func makeSession(_ source: FakeEndpointSource) -> DaemonSession {
        let session = DaemonSession(endpoints: source)
        session.retrySleep = fastSleep
        return session
    }

    /// Launch path: process reports running → session verifies the endpoint,
    /// applies the no-self-upgrade invariant, and publishes a usable API.
    @Test func connectVerifiesEnforcesAndPublishes() async throws {
        let server = FakeSyncthingServer(apiKey: "k1")
        try server.start()
        defer { server.stop() }
        let source = FakeEndpointSource(
            endpoint: .init(guiURL: server.baseURL, apiKey: "k1"))
        let session = makeSession(source)
        var states: [DaemonSession.State] = []
        session.onChange = { states.append($0) }

        session.processStateChanged(.running(guiURL: server.baseURL))
        try await expectEventually { session.api != nil }

        #expect(states.first == .connecting)
        #expect(session.api?.apiKey == "k1")
        #expect(session.api?.baseURL.absoluteString == server.baseURL)
        #expect(server.recordedAutoUpgradeIntervals == [0])

        session.processStateChanged(.stopped)
    }

    /// A process transition to anything but running tears the session down
    /// immediately — no endpoint survives a stopped/failed daemon.
    @Test func processStopUnpublishesImmediately() async throws {
        let server = FakeSyncthingServer(apiKey: "k1")
        try server.start()
        defer { server.stop() }
        let source = FakeEndpointSource(
            endpoint: .init(guiURL: server.baseURL, apiKey: "k1"))
        let session = makeSession(source)

        session.processStateChanged(.running(guiURL: server.baseURL))
        try await expectEventually { session.api != nil }

        session.processStateChanged(.stopped)
        #expect(session.state == .unavailable)
        #expect(session.api == nil)
    }

    /// The 0.1.9 headline: an API-key rotation in the daemon's own settings. The
    /// live listener rejects the old key (403) while config.xml briefly still
    /// held it — the session retries until discovery catches up, then reconnects
    /// with the new key and reapplies the invariant.
    @Test func keyRotationReconnectsWithFreshKey() async throws {
        let server = FakeSyncthingServer(apiKey: "k1")
        try server.start()
        defer { server.stop() }
        let source = FakeEndpointSource(
            endpoint: .init(guiURL: server.baseURL, apiKey: "k1"))
        let session = makeSession(source)

        session.processStateChanged(.running(guiURL: server.baseURL))
        try await expectEventually { session.api != nil }

        // Rotation: the listener switches keys first; discovery still reads k1.
        server.apiKey = "k2"
        session.endpointSuspect()
        #expect(session.state == .connecting)

        // The session must keep retrying through the stale-discovery window …
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.api == nil)

        // … and connect as soon as discovery reflects the rotation.
        source.endpoint = .init(guiURL: server.baseURL, apiKey: "k2")
        try await expectEventually { session.api?.apiKey == "k2" }
        #expect(server.recordedAutoUpgradeIntervals == [0, 0])

        session.processStateChanged(.stopped)
    }

    /// The endpoint moves (concrete-config GUI address change): the old listener
    /// refuses connections, discovery reports a new URL, the session follows.
    @Test func endpointMoveReconnectsToNewAddress() async throws {
        let serverA = FakeSyncthingServer(apiKey: "k")
        try serverA.start()
        let source = FakeEndpointSource(
            endpoint: .init(guiURL: serverA.baseURL, apiKey: "k"))
        let session = makeSession(source)

        session.processStateChanged(.running(guiURL: serverA.baseURL))
        try await expectEventually { session.api != nil }

        let serverB = FakeSyncthingServer(apiKey: "k")
        try serverB.start()
        defer { serverB.stop() }
        serverA.stop()
        source.endpoint = .init(guiURL: serverB.baseURL, apiKey: "k")

        session.endpointSuspect()
        try await expectEventually {
            session.api?.baseURL.absoluteString == serverB.baseURL
        }

        session.processStateChanged(.stopped)
    }

    /// A blip (worker restart on an unchanged endpoint): re-verification publishes
    /// the SAME identity — the premise for consumers not churning on recovery.
    @Test func blipRecoveryRepublishesSameIdentity() async throws {
        let server = FakeSyncthingServer(apiKey: "k1")
        try server.start()
        defer { server.stop() }
        let source = FakeEndpointSource(
            endpoint: .init(guiURL: server.baseURL, apiKey: "k1"))
        let session = makeSession(source)

        session.processStateChanged(.running(guiURL: server.baseURL))
        try await expectEventually { session.api != nil }
        let before = session.api

        var states: [DaemonSession.State] = []
        session.onChange = { states.append($0) }
        session.endpointSuspect()
        try await expectEventually { session.api != nil }

        #expect(states == [.connecting, .connected(before!)])
        #expect(session.api == before)

        session.processStateChanged(.stopped)
    }

    /// A process transition mid-discovery supersedes the in-flight connect loop:
    /// no stale publish can land after the daemon stopped.
    @Test func processTransitionSupersedesInFlightConnect() async throws {
        let server = FakeSyncthingServer(apiKey: "k1")
        try server.start()
        defer { server.stop() }
        let source = FakeEndpointSource(endpoint: nil)   // endpoint stays dark
        let session = makeSession(source)

        session.processStateChanged(.running(guiURL: server.baseURL))
        #expect(session.state == .connecting)

        session.processStateChanged(.stopped)
        #expect(session.state == .unavailable)

        // Even once discovery WOULD succeed, the abandoned loop must not publish.
        source.endpoint = .init(guiURL: server.baseURL, apiKey: "k1")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(session.state == .unavailable)

        // A fresh running transition connects normally.
        session.processStateChanged(.running(guiURL: server.baseURL))
        try await expectEventually { session.api != nil }
        session.processStateChanged(.stopped)
    }

    /// A suspicion only means something while connected — reported against an
    /// already-unavailable session it must not start a connect loop.
    @Test func suspectWhileUnavailableIsIgnored() async throws {
        let session = makeSession(FakeEndpointSource(endpoint: nil))
        var fired = 0
        session.onChange = { _ in fired += 1 }

        session.endpointSuspect()
        #expect(session.state == .unavailable)
        #expect(fired == 0)
    }

    /// The retry cadence: snappy start (0.5s), doubling, capped at 15s — asserted
    /// through the injected sleeper, no real time spent.
    @Test func retryBackoffDoublesToCap() async throws {
        let source = FakeEndpointSource(endpoint: nil)
        let session = DaemonSession(endpoints: source)
        var delays: [UInt64] = []
        session.retrySleep = { delay in
            delays.append(delay)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        session.processStateChanged(.running(guiURL: "http://127.0.0.1:1"))
        try await expectEventually { delays.count >= 7 }
        session.processStateChanged(.stopped)

        #expect(Array(delays.prefix(7)) == [
            500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000,
            8_000_000_000, 15_000_000_000, 15_000_000_000,
        ])
    }
}
