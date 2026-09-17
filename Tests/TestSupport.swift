import Foundation
@testable import SyncthingMenu

/// A scripted `EndpointSource` — what `SyncthingProcess.refreshEndpoint()` is in
/// production. Tests point it at a `FakeSyncthingServer` (or nowhere).
final class FakeEndpointSource: EndpointSource {
    var endpoint: SyncthingProcess.Endpoint?
    var error: Error?

    init(endpoint: SyncthingProcess.Endpoint? = nil) {
        self.endpoint = endpoint
    }

    @MainActor func refreshEndpoint() throws -> SyncthingProcess.Endpoint? {
        if let error { throw error }
        return endpoint
    }
}

/// In-memory `SecretStore` — what `KeychainSecretStore` is in production, so
/// settings tests never touch the real Keychain. Counts reads so tests can pin
/// the lazy-load contract (init and managed-mode use must never read).
final class InMemorySecretStore: SecretStore {
    private(set) var values: [String: String] = [:]
    private(set) var reads = 0

    func read(_ name: String) -> String? {
        reads += 1
        return values[name]
    }

    func write(_ name: String, value: String) {
        if value.isEmpty { values[name] = nil } else { values[name] = value }
    }
}

struct TimedOutError: Error {}

/// Poll `condition` on the main actor until it holds or `timeout` lapses. The
/// code under test is main-thread confined, so polling from the main actor with
/// suspension points is race-free by construction.
@MainActor
/// The default timeout is a CEILING, not a delay — a passing condition
/// returns at the next 20ms poll. It is generous because many waits span a
/// real localhost long-poll cycle against the fake daemon, and under a fully
/// parallel suite on a loaded machine (a CI runner, or the process tests'
/// shell spawns beside the activity tests) 5s proved too tight: two different
/// activity-feed tests timed out at 5s on 2026-09-16 while passing every
/// isolated run.
func expectEventually(timeout: TimeInterval = 20,
                      _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw TimedOutError() }
        try await Task.sleep(nanoseconds: 20_000_000)   // 20ms
    }
}

/// A near-instant `retrySleep` replacement: keeps loops from starving the main
/// actor (it still suspends) without spending real backoff time.
let fastSleep: (UInt64) async -> Void = { _ in
    try? await Task.sleep(nanoseconds: 1_000_000)       // 1ms
}
