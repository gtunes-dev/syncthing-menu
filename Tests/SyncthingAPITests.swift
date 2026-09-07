import Foundation
import Testing
@testable import SyncthingMenu

/// Request-shape tests for the REST client's per-folder verbs against
/// `FakeSyncthingServer`: the right method, path, and body reach the daemon,
/// and the state that comes back on the next config read is the daemon's.
struct SyncthingAPITests {

    /// Pausing a folder is a partial config PATCH on the folder's own path,
    /// not a call to the (device-only) pause endpoint. The next config read
    /// reflects the daemon's state — the client flips nothing itself.
    @Test func pauseFolderPatchesTheFolderConfig() async throws {
        let server = FakeSyncthingServer(apiKey: "k")
        server.folders = [.init(id: "docs id", label: "Documents")]
        try server.start()
        defer { server.stop() }
        let api = SyncthingAPI(baseURL: URL(string: server.baseURL)!, apiKey: "k")

        try await api.setFolderPaused(id: "docs id", paused: true)
        #expect(server.requestedPaths.contains("/rest/config/folders/docs%20id"))
        #expect(!server.requestedPaths.contains { $0.hasPrefix("/rest/system/pause") })
        #expect(try await api.folders().map(\.paused) == [true])

        try await api.setFolderPaused(id: "docs id", paused: false)
        #expect(try await api.folders().map(\.paused) == [false])
    }

    /// Pausing one device is the pause endpoint scoped by the device query —
    /// the same endpoint Pause All Devices uses unscoped. The next config
    /// read reflects the daemon's state.
    @Test func pauseDeviceScopesThePauseEndpoint() async throws {
        let server = FakeSyncthingServer(apiKey: "k")
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "A", paused: false),
                          .init(deviceID: "B", paused: false)]
        try server.start()
        defer { server.stop() }
        let api = SyncthingAPI(baseURL: URL(string: server.baseURL)!, apiKey: "k")

        try await api.setPaused(true, device: "A")
        #expect(server.requestedPaths.contains("/rest/system/pause?device=A"))
        #expect(try await api.devices().map(\.paused) == [false, true, false])

        try await api.setPaused(false, device: "A")
        #expect(server.requestedPaths.contains("/rest/system/resume?device=A"))
        #expect(try await api.devices().map(\.paused) == [false, false, false])

        try await api.setPaused(true)
        #expect(server.requestedPaths.contains("/rest/system/pause"))
        #expect(try await api.devices().map(\.paused) == [false, true, true])
    }

    /// A per-folder rescan is the scan endpoint scoped by the folder query;
    /// an unknown folder surfaces as the daemon's error, not silence.
    @Test func rescanFolderScopesTheScan() async throws {
        let server = FakeSyncthingServer(apiKey: "k")
        server.folders = [.init(id: "photos")]
        try server.start()
        defer { server.stop() }
        let api = SyncthingAPI(baseURL: URL(string: server.baseURL)!, apiKey: "k")

        try await api.rescan(folder: "photos")
        #expect(server.requestedPaths.contains("/rest/db/scan?folder=photos"))
        try await api.rescan()
        #expect(server.requestedPaths.contains("/rest/db/scan"))

        await #expect(throws: SyncthingAPI.APIError.self) {
            try await api.rescan(folder: "missing")
        }
    }
}
