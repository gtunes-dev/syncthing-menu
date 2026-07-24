import Foundation
import Testing
@testable import SyncthingMenu

/// Scenario tests for the activity feed's state machine against the fake
/// daemon: row lifecycles, the delivery watermark, upload marking and
/// staleness, history seeding, and the polls-only-while-visible contract.
@MainActor
struct ActivityFeedTests {

    private func api(for server: FakeSyncthingServer) -> SyncthingAPI {
        SyncthingAPI(baseURL: URL(string: server.baseURL)!, apiKey: "test-key")
    }

    /// A standard cluster: one folder, ourselves, and one named remote whose
    /// full id's 7-char prefix matches the short id disk events carry.
    private func standardServer() throws -> FakeSyncthingServer {
        let server = FakeSyncthingServer()
        try server.start()
        server.myID = "SELF"
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "REMOTE7-FULL-ID", paused: false, name: "Laptop")]
        server.folders = [.init(id: "f1", label: "Folder One")]
        return server
    }

    private func makeFeed() -> ActivityFeed {
        let feed = ActivityFeed()
        feed.retrySleep = fastSleep
        return feed
    }

    /// Count of real long-polls issued (the setup's cursor request uses
    /// timeout=1; the live loop polls with timeout=50).
    private func pollCount(_ server: FakeSyncthingServer) -> Int {
        server.requestedPaths.filter {
            $0.hasPrefix("/rest/events?") && $0.contains("timeout=50")
        }.count
    }

    /// Wait until the feed's loop is live (cursor + seed done, long-poll
    /// issued) — pushes before that land behind the cursor and vanish.
    private func waitUntilPolling(_ server: FakeSyncthingServer,
                                  beyond priorPolls: Int = 0) async throws {
        try await expectEventually { pollCount(server) > priorPolls }
    }

    // MARK: Outbound journey

    /// Local changes — deletes included (tombstones need delivering) — enter
    /// as pending rows, newest first, with the folder label resolved.
    @Test func localChangesCreatePendingRows() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "label": "Folder One", "path": "a.txt",
                                "action": "modified", "type": "file"])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "label": "Folder One", "path": "b.txt",
                                "action": "deleted", "type": "file"])
        try await expectEventually { feed.rows.count == 2 }

        #expect(feed.rows[0].path == "b.txt")
        #expect(feed.rows[0].operation == .deleted)
        #expect(feed.rows[0].state == .pending)
        #expect(feed.rows[1].path == "a.txt")
        #expect(feed.rows[1].operation == .modified)
        #expect(feed.rows[1].state == .pending)
        #expect(feed.rows.allSatisfy { $0.isLocalOrigin && $0.folderLabel == "Folder One" })
    }

    /// LocalIndexUpdated stamps the folder sequence; a remote device's
    /// FolderCompletion flips rows at/below its sequence — but not below.
    @Test func watermarkFlipsStampedRowsAtSequence() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "filenames": ["a.txt"], "sequence": 42])
        // Below the stamp: must NOT flip. The marker row proves processing.
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 50, "needItems": 3, "sequence": 41])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.rows.count == 2 }
        #expect(feed.rows.first { $0.path == "a.txt" }?.state == .pending)

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 90, "needItems": 1, "sequence": 42])
        try await expectEventually {
            feed.rows.first { $0.path == "a.txt" }?.state == .synced
        }
    }

    /// A FolderCompletion claiming to be ourselves must not flip anything;
    /// a remote's full catch-up flips even unstamped rows.
    @Test func watermarkIgnoresSelfAndFlipsOnCatchUp() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "SELF",
                                "completion": 100, "needItems": 0, "sequence": 99])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.rows.count == 2 }
        #expect(feed.rows.first { $0.path == "a.txt" }?.state == .pending)

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0])
        try await expectEventually {
            feed.rows.allSatisfy { $0.state == .synced }
        }
    }

    /// RemoteDownloadProgress marks a pending row uploading; without
    /// re-confirmation it reverts to pending after the staleness window.
    @Test func uploadingMarksAndRevertsWhenStale() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        var currentTime = Date()
        feed.now = { currentTime }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "big.mov", "action": "modified"])
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["big.mov": 7]])
        try await expectEventually { feed.rows.first?.state == .uploading }

        // Three missed report cadences: the sweep (every loop wake) reverts.
        currentTime = currentTime.addingTimeInterval(20)
        try await expectEventually { feed.rows.first?.state == .pending }
    }

    /// A newer episode for the same path supersedes its undelivered
    /// predecessor — that content will never reach anyone.
    @Test func newerEpisodeSupersedesPending() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.rows.count == 1 }
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.rows.count == 2 }

        #expect(feed.rows[0].state == .pending)
        #expect(feed.rows[1].state == .superseded)
    }

    // MARK: Inbound journey

    /// The full inbound lifecycle collapses into ONE row: started → applied,
    /// with the commit event stamping the originating device's NAME.
    @Test func inboundLifecycleCollapsesToOneRow() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "ItemStarted",
                         data: ["folder": "f1", "item": "c.txt", "action": "update",
                                "type": "file"])
        try await expectEventually { feed.rows.first?.state == .syncing }
        #expect(feed.rows.count == 1)
        #expect(feed.rows[0].isLocalOrigin == false)
        #expect(feed.rows[0].originDisplay == "—")   // origin unknown in flight

        server.pushEvent(type: "ItemFinished",
                         data: ["folder": "f1", "item": "c.txt", "action": "update",
                                "type": "file"])
        try await expectEventually { feed.rows.first?.state == .applied }

        server.pushEvent(type: "RemoteChangeDetected",
                         data: ["folder": "f1", "path": "c.txt", "action": "modified",
                                "type": "file", "modifiedBy": "REMOTE7"])
        try await expectEventually { feed.rows.first?.origin == "Laptop" }
        #expect(feed.rows.count == 1)
        #expect(feed.rows[0].operation == .modified)
    }

    /// A failed apply closes its episode; the retry starts a FRESH row at the
    /// top — chronology wins over in-place mutation.
    @Test func failedApplyThenRetryStartsFreshRow() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "ItemStarted",
                         data: ["folder": "f1", "item": "c.txt", "action": "update"])
        server.pushEvent(type: "ItemFinished",
                         data: ["folder": "f1", "item": "c.txt", "action": "update",
                                "error": "permission denied"])
        try await expectEventually {
            feed.rows.first?.state == .failed("permission denied")
        }

        server.pushEvent(type: "ItemStarted",
                         data: ["folder": "f1", "item": "c.txt", "action": "update"])
        try await expectEventually { feed.rows.count == 2 }
        #expect(feed.rows[0].state == .syncing)
        #expect(feed.rows[1].state == .failed("permission denied"))
    }

    // MARK: Seeding & frugality

    /// The disk-events ring seeds history on first connect (newest first,
    /// settled states, origin resolved); a reconnect must NOT re-seed.
    @Test func seedsHistoryOnceOnly() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.seedDiskEvent(type: "LocalChangeDetected",
                             data: ["folder": "f1", "label": "Folder One", "path": "old.txt",
                                    "action": "modified", "type": "file"])
        server.seedDiskEvent(type: "RemoteChangeDetected",
                             data: ["folder": "f1", "label": "Folder One", "path": "newer.txt",
                                    "action": "modified", "type": "file",
                                    "modifiedBy": "REMOTE7"])
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await expectEventually { feed.rows.count == 2 }

        #expect(feed.rows[0].path == "newer.txt")
        #expect(feed.rows[0].state == .applied)
        #expect(feed.rows[0].origin == "Laptop")
        #expect(feed.rows[1].path == "old.txt")
        #expect(feed.rows[1].state == .pending)

        // Session republish → loop restarts; rows are kept, history is not
        // re-applied (no duplicates).
        let polls = pollCount(server)
        feed.connect(api: api(for: server))
        try await waitUntilPolling(server, beyond: polls)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "live.txt", "action": "modified"])
        try await expectEventually { feed.rows.contains { $0.path == "live.txt" } }
        #expect(feed.rows.count == 3)
    }

    /// The frugality contract: a connected feed with no visible window issues
    /// NO requests at all; closing the window stops the traffic again.
    @Test func pollsOnlyWhileWindowVisible() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(server.requestedPaths.isEmpty)

        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        feed.setWindowVisible(false)
        try await Task.sleep(nanoseconds: 400_000_000)   // drain in-flight poll
        let quiesced = server.requestedPaths.count
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(server.requestedPaths.count == quiesced)
    }
}
