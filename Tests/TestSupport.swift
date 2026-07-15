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

    func refreshEndpoint() throws -> SyncthingProcess.Endpoint? {
        if let error { throw error }
        return endpoint
    }
}

struct TimedOutError: Error {}

/// Poll `condition` on the main actor until it holds or `timeout` lapses. The
/// code under test is main-thread confined, so polling from the main actor with
/// suspension points is race-free by construction.
@MainActor
func expectEventually(timeout: TimeInterval = 5,
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
