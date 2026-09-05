import Foundation
import Testing
@testable import SyncthingMenu

/// Scenario tests for the activity log against the fake daemon: entry
/// creation from witnessed events, the same-batch collapse, author
/// enrichment, and the recording lifecycle (policy × window × session:
/// pause flushes loops and keeps rows, disconnect keeps both, the
/// commit-epoch guard).
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
                          .init(deviceID: "REMOTE7-FULL-ID", paused: false, name: "Laptop",
                                connected: true)]
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
    private func waitUntilPolling(_ server: FakeSyncthingServer) async throws {
        try await expectEventually { pollCount(server) > 0 }
    }

    // MARK: Detections (outbound observations)

    /// Local changes — deletes included (a tombstone is a change too) —
    /// append detected entries, newest first, party "This Mac", with the
    /// folder label resolved.
    @Test func localChangesAppendDetectedEntries() async throws {
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
        try await expectEventually { feed.activity.count == 2 }

        #expect(feed.activity[0].path == "b.txt")
        #expect(feed.activity[0].operation == .deleted)
        #expect(feed.activity[1].path == "a.txt")
        #expect(feed.activity[1].operation == .modified)
        #expect(feed.activity.allSatisfy {
            $0.kind == .detected && $0.partyDisplay == "This Mac"
                && $0.folderLabel == "Folder One"
        })
    }

    /// The log never supersedes: a second change to the same path is simply
    /// a newer entry — the older one is history, untouched.
    @Test func repeatedChangesAppendWithoutMutatingHistory() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 2 }

        #expect(feed.activity.allSatisfy { $0.kind == .detected && $0.path == "a.txt" })
    }

    // MARK: Outbound synthesis

    /// A path APPEARING in a device's progress report logs a sending entry —
    /// create-on-mention, no witnessed detect required — and a repeat report
    /// of the same set logs nothing (the diff is empty).
    @Test func appearanceLogsSendingOnceAcrossRepeatReports() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["unseen.bin": 3]])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].kind == .sending)
        #expect(feed.activity[0].path == "unseen.bin")
        #expect(feed.activity[0].partyDisplay == "Laptop")
        #expect(feed.activity[0].folderLabel == "Folder One")

        // Same set again (the ~5s cadence): no new entries. Marker proves
        // the batch was processed.
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["unseen.bin": 7]])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 2 }
        #expect(feed.activity.filter { $0.kind == .sending }.count == 1)
    }

    /// A path DISAPPEARING from the report (here via the final empty state
    /// map) means the transfer ended; the availability read confirms the
    /// device has it → a delivered entry. The sending entry REMAINS — it
    /// happened.
    @Test func disappearanceConfirmedByAvailabilityLogsDelivered() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.setFileAvailability(folder: "f1", path: "big.mov",
                                   devices: ["REMOTE7-FULL-ID"])
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["big.mov": 9]])
        try await expectEventually { feed.activity.count == 1 }

        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": [String: Int]()])
        try await expectEventually {
            feed.activity.first?.kind == .delivered
        }
        #expect(feed.activity.count == 2)
        #expect(feed.activity[0].partyDisplay == "Laptop")
        #expect(feed.activity[1].kind == .sending)
    }

    /// A transfer that ends WITHOUT the index confirming delivery (failed,
    /// re-queued, or the lookup 404s) logs nothing — lag, never lie.
    @Test func unconfirmedDisappearanceLogsNothing() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["gone.bin": 2]])
        try await expectEventually { feed.activity.count == 1 }
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": [String: Int]()])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 2 }
        #expect(!feed.activity.contains { $0.kind == .delivered })
    }

    /// Per-file confirmation via remoteneed: partial catch-up progress
    /// triggers ONE bounded query; tracked paths absent from the complete
    /// need list log delivered entries individually, listed paths stay
    /// unconfirmed — and nothing further queries once nothing is tracked.
    @Test func remoteNeedConfirmsDeliveriesIndividually() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "b.txt", "action": "deleted"])
        try await expectEventually { feed.activity.count == 2 }

        // The peer still needs b.txt; a.txt is absent — delivered. The
        // delete stays tracked (tombstones need delivering too).
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID", names: ["b.txt"])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 50, "needItems": 1])
        try await expectEventually {
            feed.activity.contains {
                $0.kind == .delivered && $0.path == "a.txt" && $0.partyDisplay == "Laptop"
            }
        }
        #expect(!feed.activity.contains { $0.kind == .delivered && $0.path == "b.txt" })
        let needQueries = { server.requestedPaths.filter {
            $0.hasPrefix("/rest/db/remoteneed") }.count }
        #expect(needQueries() == 1)

        // b.txt confirms next tick; then, with nothing tracked, a further
        // tick must not query at all (marker proves processing).
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID", names: [])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 80, "needItems": 1])
        try await expectEventually {
            feed.activity.contains { $0.kind == .delivered && $0.path == "b.txt" }
        }
        #expect(feed.activity.first { $0.kind == .delivered && $0.path == "b.txt" }?
            .operation == .deleted)
        let after = needQueries()
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 90, "needItems": 1])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "x", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "x" } }
        #expect(needQueries() == after)
    }

    /// A full (possibly truncated) need page proves nothing about absences:
    /// no delivery may be logged off it.
    @Test func truncatedRemoteNeedListIsNotTrusted() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        // files.count == perpage → the page is full; a.txt's absence from it
        // is meaningless.
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID",
                             names: ["other.txt"], perpage: 1)
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 50, "needItems": 1])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 2 }
        #expect(!feed.activity.contains { $0.kind == .delivered })
    }

    /// Full catch-up confirms every tracked path INDIVIDUALLY: the device
    /// needs nothing, so each undelivered item we were tracking gets its own
    /// delivered entry (the tracker turns folder-level evidence into
    /// per-item conclusions). The tracker clears — a second catch-up logs
    /// nothing.
    @Test func fullCatchUpConfirmsEachTrackedItem() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        for (path, action) in [("a.txt", "modified"), ("b.txt", "modified"),
                               ("c.txt", "deleted")] {
            server.pushEvent(type: "LocalChangeDetected",
                             data: ["folder": "f1", "path": path, "action": action])
        }
        try await expectEventually { feed.activity.count == 3 }

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually { feed.activity.count == 6 }
        let delivered = feed.activity.filter { $0.kind == .delivered }
        #expect(Set(delivered.map(\.path)) == ["a.txt", "b.txt", "c.txt"])
        #expect(delivered.allSatisfy { $0.partyDisplay == "Laptop" })
        // The delete's delivery carries its operation (tombstone delivered).
        #expect(delivered.first { $0.path == "c.txt" }?.operation == .deleted)

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "marker", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker" } }
        #expect(feed.activity.filter { $0.kind == .delivered }.count == 3)
    }

    /// Delivered dedupe is scoped to the EPISODE: a re-changed path's next
    /// delivery logs its own entry (a churning file shows every cycle), while
    /// overlapping confirmation paths within one episode — here remoteneed
    /// first, then the transfer-end availability check for the same delivery
    /// — still log it exactly once.
    @Test func redetectedPathLogsEachDeliveryButNeverDoubleLogs() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.setFileAvailability(folder: "f1", path: "churn.plist",
                                   devices: ["REMOTE7-FULL-ID"])
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        let deliveredCount = {
            feed.activity.filter { $0.kind == .delivered && $0.path == "churn.plist" }.count
        }

        // Episode 1: detected, mentioned, confirmed via remoteneed…
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "churn.plist", "action": "modified"])
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["churn.plist": 2]])
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID", names: [])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 50, "needItems": 1])
        try await expectEventually { deliveredCount() == 1 }

        // …then the SAME delivery's transfer-end availability check resolves:
        // still one entry (marker proves the batch processed).
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": [String: Int]()])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker1.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker1.txt" } }
        #expect(deliveredCount() == 1)

        // Episode 2: the file churns again — its new delivery logs again.
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "churn.plist", "action": "modified"])
        try await expectEventually {
            feed.activity.first { $0.path == "churn.plist" }?.kind == .detected
        }
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually { deliveredCount() == 2 }
    }

    /// Completion 100 with undelivered tombstones (needDeletes > 0) is NOT a
    /// catch-up; and a FolderCompletion claiming to be ourselves never
    /// confirms anything.
    @Test func catchUpRequiresZeroDeletesAndIgnoresSelf() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "deleted"])
        try await expectEventually { feed.activity.count == 1 }

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 2])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "SELF",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 2 }
        #expect(!feed.activity.contains { $0.kind == .delivered })
    }

    // MARK: The bulk tier (machine-scale churn)

    /// A batch carrying more detections than the bulk threshold for one
    /// folder is machine-scale churn: it logs ONE bulk detected entry (the
    /// count), not a wall of rows — and the matching ending arrives at the
    /// same granularity: one bulk delivered entry on catch-up.
    @Test func burstAboveThresholdCoalescesToBulkEntries() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        let count = ActivityFeed.bulkDetectionThreshold + 5
        let burst = (1...count).map { index in
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "churn/file\(index).dat",
                    "action": "modified"] as [String: Any])
        }
        server.pushEvents(burst)
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].kind == .detected)
        #expect(feed.activity[0].bulkCount == count)
        #expect(feed.activity[0].displayName == "\(count) changes")
        #expect(feed.activity[0].partyDisplay == "This Mac")
        #expect(feed.activity[0].folderLabel == "Folder One")

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually { feed.activity.first?.kind == .delivered }
        #expect(feed.activity.first?.bulkCount == count)
        #expect(feed.activity.first?.partyDisplay == "Laptop")
        #expect(feed.activity.count == 2)
    }

    /// The LocalIndexUpdated backstop, named tier: when the event's
    /// filenames are complete, unwitnessed items are recovered as REAL
    /// per-item detections (name shown, loop opened), never as a "N changes"
    /// row — and they close individually like any other loop.
    @Test func indexUpdateBackstopRecoversMissedChangesByName() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "seen.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        // The index batch covers three items; we witnessed one — the other
        // two are recovered by name, not aggregated.
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": 3,
                                "filenames": ["seen.txt", "ghost1.txt", "ghost2.txt"]])
        try await expectEventually { feed.activity.count == 3 }
        for ghost in ["ghost1.txt", "ghost2.txt"] {
            let entry = feed.activity.first { $0.path == ghost }
            #expect(entry?.kind == .detected)
            #expect(entry?.bulkCount == nil)
            #expect(entry?.partyDisplay == "This Mac")
        }
        #expect(feed.activity.filter { $0.path == "seen.txt" }.count == 1)   // no duplicate

        // Recovered loops close per-item on catch-up.
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually {
            feed.activity.contains { $0.kind == .delivered && $0.path == "ghost1.txt" }
        }
        #expect(!feed.activity.contains { $0.bulkCount != nil })
    }

    /// The daemon may emit LocalIndexUpdated BEFORE the change events it
    /// covers (observed live 2026-08-18 as doubled detected rows): the
    /// backstop recovers the names, and the late-arriving change events
    /// consume the recovery markers instead of logging duplicates. A
    /// genuinely NEW change afterwards still logs its own entry.
    @Test func indexUpdateArrivingFirstDoesNotDuplicateDetections() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        // Adversarial order, one batch: the index event first, then the
        // change events it covers.
        server.pushEvents([
            (type: "LocalIndexUpdated",
             data: ["folder": "f1", "items": 2, "filenames": ["a.txt", "b.txt"]]),
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "a.txt", "action": "modified"]),
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "b.txt", "action": "modified"]),
        ])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker.txt" } }
        #expect(feed.activity.filter { $0.path == "a.txt" }.count == 1)
        #expect(feed.activity.filter { $0.path == "b.txt" }.count == 1)
        #expect(feed.activity.count == 3)

        // The marker is consumed: a real second change logs normally.
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually {
            feed.activity.filter { $0.path == "a.txt" }.count == 2
        }
    }

    /// A DELETE whose index event wins the race: recovery guesses modify
    /// (filenames carry no operation), and the late change event must
    /// correct both the entry and the loop — detected AND delivered render
    /// as a deletion (regressed and caught live 2026-08-18: a real delete
    /// showed pencils end to end).
    @Test func recoveredDeleteGainsTrueOperationThroughDelivery() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvents([
            (type: "LocalIndexUpdated",
             data: ["folder": "f1", "items": 1, "filenames": ["gone.txt"]]),
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "gone.txt", "action": "deleted"]),
        ])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker.txt" } }
        let detected = feed.activity.filter { $0.path == "gone.txt" }
        #expect(detected.count == 1)
        #expect(detected.first?.operation == .deleted)

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually {
            feed.activity.contains { $0.kind == .delivered && $0.path == "gone.txt" }
        }
        #expect(feed.activity.first {
            $0.kind == .delivered && $0.path == "gone.txt"
        }?.operation == .deleted)
    }

    /// The backstop's unnamed tier: with filenames truncated or absent, only
    /// the count is trustworthy — an over-threshold surplus logs one bulk
    /// entry, while a small unnamed surplus is suppressed entirely (the
    /// spurious "1 change" rows seen live 2026-08-17 were exactly this
    /// bookkeeping slop rendered as fact).
    @Test func indexUpdateUnnamedSurplusAggregatesOrSuppresses() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        // Small unnamed surplus (5 items, nothing witnessed, no filenames):
        // suppressed — no entry at all (marker proves processing).
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": 5])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker.txt" } }
        #expect(feed.activity.count == 1)

        // Large surplus with truncated filenames (count != items): the
        // count is real churn scale — one bulk entry, closed in bulk.
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": 60,
                                "filenames": ["partial1.txt", "partial2.txt"]])
        try await expectEventually {
            // 60 items minus the one witnessed marker = 59 unwitnessed.
            feed.activity.contains { $0.kind == .detected && $0.bulkCount == 59 }
        }

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually {
            feed.activity.contains { $0.kind == .delivered && $0.bulkCount == 59 }
        }
    }

    // MARK: The quiescence sweep

    /// A loop whose confirming event never arrives (missed cue) is closed by
    /// the sweep: once the loop is stale, a wake probes our own index — a
    /// caught-up device closes the folder's loops. Before the staleness
    /// threshold, the sweep costs nothing.
    @Test func sweepClosesStaleLoopsAgainstCaughtUpFolder() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.setCompletion(folder: "f1", device: "REMOTE7-FULL-ID", needItems: 0)
        let feed = makeFeed()
        defer { feed.disconnect() }
        var currentTime = Date()
        feed.now = { currentTime }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        // Fresh loop: wakes come and go (the fake's parks cycle fast), but
        // no probe is issued below the staleness threshold.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!server.requestedPaths.contains { $0.contains("/rest/db/completion") })

        // NO FolderCompletion ever arrives (the missed-cue scenario). Going
        // stale, the next wake probes completion and closes the loop.
        currentTime = currentTime.addingTimeInterval(31)
        try await expectEventually { feed.activity.first?.kind == .delivered }
        #expect(feed.activity.first?.path == "a.txt")
        #expect(feed.activity.first?.partyDisplay == "Laptop")
        #expect(server.requestedPaths.contains { $0.contains("/rest/db/completion") })
    }

    /// A stale loop against a PARTIALLY-synced folder falls back to one
    /// remoteneed page: absent tracked paths close, listed ones stay open.
    @Test func sweepConfirmsPartialFolderViaRemoteneed() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.setCompletion(folder: "f1", device: "REMOTE7-FULL-ID", needItems: 1)
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID",
                             names: ["still-needed.txt"])
        let feed = makeFeed()
        defer { feed.disconnect() }
        var currentTime = Date()
        feed.now = { currentTime }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "still-needed.txt",
                                "action": "modified"])
        try await expectEventually { feed.activity.count == 2 }

        currentTime = currentTime.addingTimeInterval(31)
        try await expectEventually {
            feed.activity.contains { $0.kind == .delivered && $0.path == "a.txt" }
        }
        #expect(!feed.activity.contains {
            $0.kind == .delivered && $0.path == "still-needed.txt"
        })
    }

    // MARK: Delivery expectation (loops open only where an ending is owed)

    /// A receive-only folder never sends its local changes — and its local
    /// additions are EXCLUDED from the global index, so a remote reads
    /// completion 100 immediately. Detected entries still log (true, and
    /// revert-worthy), but no loop opens: without this gate the catch-up
    /// would synthesize a false "Delivered" (the 2026-08-17 enumeration's
    /// one real lie).
    @Test func receiveOnlyFolderDetectsWithoutPromisingDelivery() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.folders = [.init(id: "f1", label: "Folder One", type: "receiveonly")]
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "stray.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].kind == .detected)

        // The remote reads fully caught up — but nothing was promised, so
        // nothing "delivers" (marker proves the batch processed).
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker.txt" } }
        #expect(!feed.activity.contains { $0.kind == .delivered })
    }

    /// A folder shared with nobody can deliver to nobody: detections stand
    /// alone, no loop opens, and the sweep never probes for it — even long
    /// past the staleness threshold.
    @Test func unsharedFolderOpensNoLoopsAndCostsNothing() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.folders = [.init(id: "f1", label: "Folder One", sharedWith: ["SELF"])]
        let feed = makeFeed()
        defer { feed.disconnect() }
        var currentTime = Date()
        feed.now = { currentTime }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "solo.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        currentTime = currentTime.addingTimeInterval(31)
        try await Task.sleep(nanoseconds: 400_000_000)   // several empty wakes
        #expect(!server.requestedPaths.contains { $0.contains("/rest/db/completion") })
        #expect(!feed.activity.contains { $0.kind == .delivered })
        #expect(feed.activity.first?.kind == .detected)
    }

    // MARK: Identity upkeep

    /// ConfigSaved re-reads the identity tables, so folder labels and device
    /// names can't go stale while the window is open.
    @Test func configSavedRefreshesIdentityTables() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        let folderReads = { server.requestedPaths.filter {
            $0.hasPrefix("/rest/config/folders") }.count }
        let before = folderReads()
        server.folders = [.init(id: "f1", label: "Renamed")]
        server.pushEvent(type: "ConfigSaved")
        try await expectEventually { folderReads() > before }

        // A change event WITHOUT its own label field resolves through the
        // refreshed table.
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "y.txt", "action": "modified"])
        try await expectEventually {
            feed.activity.first { $0.path == "y.txt" }?.folderLabel == "Renamed"
        }
    }

    // MARK: Inbound entries

    /// ItemStarted + ItemFinished in ONE poll batch — the normal case for
    /// small files — collapse to a single applied entry: one fact, not two
    /// rows dated a millisecond apart.
    @Test func sameBatchStartAndFinishCollapseToApplied() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvents([
            (type: "ItemStarted",
             data: ["folder": "f1", "item": "c.txt", "action": "update", "type": "file"]),
            (type: "ItemFinished",
             data: ["folder": "f1", "item": "c.txt", "action": "update", "type": "file"]),
        ])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].kind == .applied)
        #expect(feed.activity[0].partyDisplay == "—")   // author unknown until the commit event
        #expect(feed.activity[0].folderLabel == "Folder One")
    }

    /// A start that outlives its batch logs a downloading entry; the finish
    /// later appends its own applied entry — the downloading entry REMAINS,
    /// because it happened.
    @Test func crossBatchFinishAppendsAndKeepsDownloading() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "ItemStarted",
                         data: ["folder": "f1", "item": "big.mov", "action": "update"])
        try await expectEventually { feed.activity.first?.kind == .downloading }

        server.pushEvent(type: "ItemFinished",
                         data: ["folder": "f1", "item": "big.mov", "action": "update"])
        try await expectEventually { feed.activity.count == 2 }
        #expect(feed.activity[0].kind == .applied)
        #expect(feed.activity[1].kind == .downloading)
        #expect(feed.activity.allSatisfy { $0.path == "big.mov" })
    }

    /// A failed apply logs a failed entry carrying the error; a later retry
    /// appends fresh entries above it — the failure stays in the record.
    @Test func failedApplyLogsErrorAndRetryAppends() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvents([
            (type: "ItemStarted",
             data: ["folder": "f1", "item": "c.txt", "action": "update"]),
            (type: "ItemFinished",
             data: ["folder": "f1", "item": "c.txt", "action": "update",
                    "error": "permission denied"]),
        ])
        try await expectEventually {
            feed.activity.first?.kind == .failed("permission denied")
        }
        #expect(feed.activity.count == 1)

        server.pushEvent(type: "ItemStarted",
                         data: ["folder": "f1", "item": "c.txt", "action": "update"])
        try await expectEventually { feed.activity.count == 2 }
        #expect(feed.activity[0].kind == .downloading)
        #expect(feed.activity[1].kind == .failed("permission denied"))
    }

    /// The commit event ENRICHES the applied entry with its author's name —
    /// metadata enrichment of an existing entry, never a new row and never a
    /// state change.
    @Test func remoteChangeEnrichesAppliedAuthor() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvents([
            (type: "ItemStarted",
             data: ["folder": "f1", "item": "c.txt", "action": "update"]),
            (type: "ItemFinished",
             data: ["folder": "f1", "item": "c.txt", "action": "update"]),
        ])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].partyDisplay == "—")

        server.pushEvent(type: "RemoteChangeDetected",
                         data: ["folder": "f1", "path": "c.txt", "action": "modified",
                                "type": "file", "modifiedBy": "REMOTE7"])
        try await expectEventually { feed.activity.first?.partyDisplay == "Laptop" }
        #expect(feed.activity.count == 1)
        #expect(feed.activity[0].kind == .applied)
    }

    /// A commit event with no witnessed apply (subscription started
    /// mid-apply) still logs the settled inbound change, author included.
    @Test func standaloneRemoteChangeCreatesAppliedEntry() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "RemoteChangeDetected",
                         data: ["folder": "f1", "path": "gone.txt", "action": "deleted",
                                "type": "file", "modifiedBy": "REMOTE7"])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].kind == .applied)
        #expect(feed.activity[0].operation == .deleted)
        #expect(feed.activity[0].partyDisplay == "Laptop")
    }

    // MARK: Lifecycle & frugality

    /// The witnessed-activity model: the window NEVER seeds entries — a huge
    /// standing backlog produces an EMPTY open (the queue's home is the
    /// Devices panel), and only events witnessed after open create entries.
    @Test func opensEmptyRegardlessOfBacklog() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.setCompletion(folder: "f1", device: "REMOTE7-FULL-ID", needItems: 66_000)
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID",
                             names: ["queued-a.txt", "queued-b.txt"])
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        #expect(feed.activity.isEmpty)
        #expect(!server.requestedPaths.contains { $0.contains("db/remoteneed") })

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "observed.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].kind == .detected)
    }

    // MARK: Recording lifecycle (policy × window × session)

    /// Count of cursor requests (`since=0&timeout=1&limit=1`) — one per loop
    /// (re)start, so it tells a restart from a continuing loop.
    private func loopStartCount(_ server: FakeSyncthingServer) -> Int {
        server.requestedPaths.filter {
            $0.hasPrefix("/rest/events?") && $0.contains("timeout=1&")
        }.count
    }

    private func pushFullCatchUp(_ server: FakeSyncthingServer) {
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
    }

    /// Closing the window is a PAUSE: the log keeps its rows, the open loops
    /// are flushed (stale the moment nobody watches). A reopen is a fresh
    /// open against retained rows — a catch-up after it confirms nothing
    /// from before the pause, while new activity appends on top.
    @Test func closingKeepsEntriesAndFlushesOpenLoops() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "seen.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        feed.setWindowVisible(false)
        #expect(feed.activity.count == 1)

        let polls = pollCount(server)
        feed.setWindowVisible(true)
        try await expectEventually { pollCount(server) > polls }
        #expect(feed.activity.count == 1)

        pushFullCatchUp(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "after.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "after.txt" } }
        #expect(feed.activity.count == 2)
        #expect(!feed.activity.contains { $0.kind == .delivered })
    }

    /// A DISCONNECT keeps the open loops (nothing syncs while the daemon is
    /// down): after the reconnect their endings arrive from real events.
    @Test func disconnectKeepsOpenLoopsForReconnect() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        feed.disconnect()
        #expect(feed.activity.count == 1)

        let polls = pollCount(server)
        feed.connect(api: api(for: server))
        try await expectEventually { pollCount(server) > polls }
        pushFullCatchUp(server)
        try await expectEventually { feed.activity.first?.kind == .delivered }
        #expect(feed.activity.first?.path == "a.txt")
    }

    /// Policy `always`: the loop runs from connect with no window, and the
    /// window opening and closing is not a pause — the loops survive.
    @Test func alwaysPolicyRecordsWithWindowClosed() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.setRecordingPolicy(.always)
        feed.connect(api: api(for: server))
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        feed.setWindowVisible(true)
        feed.setWindowVisible(false)
        #expect(loopStartCount(server) == 1)
        #expect(feed.activity.count == 1)

        pushFullCatchUp(server)
        try await expectEventually { feed.activity.first?.kind == .delivered }
    }

    /// Switching to `always` with the window closed starts recording;
    /// switching back with it closed pauses (traffic stops, rows stay,
    /// loops flushed); reopening resumes fresh.
    @Test func policySwitchesWithWindowClosedStartAndPause() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(server.requestedPaths.isEmpty)

        feed.setRecordingPolicy(.always)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        feed.setRecordingPolicy(.whileWindowOpen)
        try await Task.sleep(nanoseconds: 400_000_000)   // drain in-flight poll
        let quiesced = server.requestedPaths.count
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(server.requestedPaths.count == quiesced)
        #expect(feed.activity.count == 1)

        feed.setWindowVisible(true)
        try await expectEventually { pollCount(server) > quiesced }
        pushFullCatchUp(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "marker", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker" } }
        #expect(!feed.activity.contains { $0.kind == .delivered })
    }

    /// A policy change while the window is open changes nothing: recording
    /// was wanted before and after, so the loop neither restarts nor pauses.
    @Test func policyChangeWhileWindowOpenIsANoOp() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        feed.setRecordingPolicy(.always)
        feed.setRecordingPolicy(.whileWindowOpen)
        #expect(loopStartCount(server) == 1)
        pushFullCatchUp(server)
        try await expectEventually { feed.activity.first?.kind == .delivered }
    }

    /// Wanted before possible: an open window with no endpoint issues no
    /// requests, and the loop starts the moment the session connects.
    @Test func windowOpenBeforeConnectStartsOnConnect() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.setWindowVisible(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.requestedPaths.isEmpty)

        feed.connect(api: api(for: server))
        try await waitUntilPolling(server)
    }

    /// The commit-epoch contract: a batch parked on a network await when
    /// the window closes must not, on resuming, overwrite the paused log
    /// with the snapshot it took before the pause.
    @Test func staleBatchNeverOverwritesAPause() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        // This batch adds b.txt, then parks on the remoteneed read its
        // completion cue triggers.
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID", names: [])
        server.holdRequests(containing: "db/remoteneed")
        server.pushEvents([
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "b.txt", "action": "modified"]),
            (type: "FolderCompletion",
             data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                    "completion": 50, "needItems": 1]),
        ])
        try await expectEventually { server.heldRequestCount == 1 }
        #expect(feed.activity.count == 1)   // parked: nothing committed yet

        feed.setWindowVisible(false)
        #expect(feed.activity.count == 1)

        server.releaseHeldRequests()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(feed.activity.count == 1)
        #expect(feed.activity.first?.path == "a.txt")
    }

    // MARK: Markers (the log's own lifecycle)

    private func kinds(_ feed: ActivityFeed) -> [ActivityFeed.Entry.Kind] {
        feed.entries.reversed().map(\.kind)   // oldest first
    }

    /// Markers follow FLIPS of "recording wanted" (unconditionally) and of
    /// the endpoint (only while wanted), never repeats: the inputs
    /// re-announce unchanged states and the session republishes connect on
    /// every blip recovery. Timestamps come from the feed's clock.
    @Test func markersFollowFlipsOnly() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        let clock = Date(timeIntervalSinceReferenceDate: 1_000)
        feed.now = { clock }

        feed.setWindowVisible(true)       // wanted, not yet possible
        feed.setWindowVisible(true)       // repeat: nothing
        #expect(kinds(feed) == [.recordingStarted(.windowOpened)])
        #expect(feed.entries[0].time == clock)
        #expect(feed.entries[0].path.isEmpty && feed.entries[0].party == nil)

        feed.connect(api: api(for: server))
        feed.connect(api: api(for: server))   // republish: nothing
        #expect(kinds(feed) == [.recordingStarted(.windowOpened), .connected])

        feed.disconnect()
        feed.disconnect()                      // repeat: nothing
        feed.setWindowVisible(false)           // paused while disconnected
        #expect(kinds(feed) == [.recordingStarted(.windowOpened), .connected,
                                .disconnected, .recordingPaused(.windowClosed)])

        feed.connect(api: api(for: server))    // not wanted: no marker
        feed.setRecordingPolicy(.always)
        feed.setRecordingPolicy(.always)       // repeat: nothing
        feed.setRecordingPolicy(.whileWindowOpen)
        #expect(kinds(feed) == [.recordingStarted(.windowOpened), .connected,
                                .disconnected, .recordingPaused(.windowClosed),
                                .recordingStarted(.policySetToAlways),
                                .recordingPaused(.policySetToWhileWindowOpen)])
        #expect(feed.entries.allSatisfy { $0.kind.isMarker && $0.displayName != "" })
    }

    /// Launch under `always` is a transition: the log opens with a started
    /// marker, then connected once the session publishes.
    @Test func launchWithAlwaysBeginsStartedThenConnected() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.setRecordingPolicy(.always)
        feed.connect(api: api(for: server))
        #expect(kinds(feed) == [.recordingStarted(.policySetToAlways), .connected])
    }

    /// A paused period hides everything — daemon restarts included: the
    /// endpoint flipping while recording is not wanted leaves no marker.
    /// Opening while already connected logs started only (the endpoint
    /// didn't flip; the header's live status carries the daemon state).
    @Test func endpointFlipsWhilePausedLeaveNoTrace() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        feed.setWindowVisible(false)
        feed.disconnect()
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        #expect(kinds(feed) == [.recordingStarted(.windowOpened),
                                .recordingPaused(.windowClosed),
                                .recordingStarted(.windowOpened)])
    }

    /// Markers sort after every sync verb in attention order and land in
    /// the log's normal newest-first position among real entries.
    @Test func markersInterleaveWithActivity() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 2 }
        feed.setWindowVisible(false)
        #expect(kinds(feed) == [.recordingStarted(.windowOpened), .detected,
                                .recordingPaused(.windowClosed)])
        #expect(feed.entries[0].kindSortKey > feed.entries[1].kindSortKey)
    }

    // MARK: Daemon events (folder & device rows)

    private func daemonRows(_ feed: ActivityFeed) -> [ActivityFeed.Entry] {
        feed.entries.filter { $0.kind.isDaemonEvent }
    }

    /// Pause/resume events log one row per subject, and a same-batch burst
    /// (Pause All Devices) coalesces to one "N devices" row. Folder events
    /// name the folder via `id` + `label`.
    @Test func pauseAndResumeRowsCoalescePerBatch() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.devices.append(.init(deviceID: "OTHER77-FULL-ID", paused: false, name: "Desk"))
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "DevicePaused", data: ["device": "REMOTE7-FULL-ID"])
        try await expectEventually { daemonRows(feed).count == 1 }
        #expect(daemonRows(feed)[0].kind == .devicePaused)
        #expect(daemonRows(feed)[0].partyDisplay == "Laptop")
        #expect(daemonRows(feed)[0].displayName == "")

        server.pushEvents([
            (type: "DeviceResumed", data: ["device": "REMOTE7-FULL-ID"]),
            (type: "DeviceResumed", data: ["device": "OTHER77-FULL-ID"]),
            (type: "FolderPaused", data: ["id": "f1", "label": "Folder One"]),
        ])
        try await expectEventually { daemonRows(feed).count == 3 }
        let resumed = daemonRows(feed).first { $0.kind == .deviceResumed }
        #expect(resumed?.partyDisplay == "2 devices" && resumed?.bulkCount == 2)
        let folderPaused = daemonRows(feed).first { $0.kind == .folderPaused }
        #expect(folderPaused?.folderLabel == "Folder One" && folderPaused?.folderID == "f1")
        #expect(folderPaused?.party == nil)
    }

    /// Peers coming and going log online/offline rows (the `id`-shaped
    /// connectivity events) on the DEVICE-level flip only: the daemon
    /// emits DeviceConnected per connection (relay→direct upgrades, second
    /// connections), so repeats for an already-connected peer — including
    /// one connected at seed time — log nothing. Never for ourselves.
    @Test func peerConnectivityLogsOnlineAndOfflineOnFlipsOnly() async throws {
        let server = try standardServer()   // Laptop is connected at seed
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "DeviceConnected", data: ["id": "REMOTE7-FULL-ID"])   // upgrade
        server.pushEvent(type: "DeviceConnected", data: ["id": "SELF"])
        server.pushEvent(type: "DeviceDisconnected", data: ["id": "REMOTE7-FULL-ID"])
        server.pushEvent(type: "DeviceDisconnected", data: ["id": "REMOTE7-FULL-ID"])  // repeat
        server.pushEvent(type: "DeviceConnected", data: ["id": "REMOTE7-FULL-ID"])
        server.pushEvent(type: "DeviceConnected", data: ["id": "REMOTE7-FULL-ID"])    // second conn
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "marker", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker" } }
        #expect(daemonRows(feed).map(\.kind) == [.deviceOnline, .deviceOffline])
        #expect(daemonRows(feed).allSatisfy { $0.partyDisplay == "Laptop" })
    }

    /// The bulk twin of the index-first duplicate guard: an index event
    /// arriving BEFORE its change events at scale logs one bulk recovery,
    /// and the change events that follow consume that budget instead of
    /// coalescing into a second identical "N changes" row. The budget
    /// retires at the next index cycle, so later changes log normally.
    @Test func indexUpdateArrivingFirstAtBulkScaleDoesNotDouble() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        let count = ActivityFeed.bulkDetectionThreshold + 5
        let names = (1...count).map { "bulk-\($0).txt" }
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": count, "filenames": names])
        try await expectEventually { feed.activity.count == 1 }
        #expect(feed.activity[0].bulkCount == count)

        server.pushEvents(names.map {
            (type: "LocalChangeDetected", data: ["folder": "f1", "path": $0, "action": "modified"])
        })
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "marker", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker" } }
        #expect(feed.activity.filter { $0.bulkCount != nil }.count == 1)
        #expect(feed.activity.count == 2)

        // Next index cycle retires the budget: a fresh change logs.
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": count, "filenames": names])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "later.txt", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "later.txt" } }
    }

    /// A folder entering `error` logs the status text via one bounded read;
    /// watcher failures and recoveries log as such. Scan transitions log
    /// NOTHING — the event can't say why a folder scanned (class doc).
    @Test func folderErrorAndWatchRows() async throws {
        let server = try standardServer()
        defer { server.stop() }
        server.folders = [.init(id: "f1", label: "Folder One", error: "folder path missing")]
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "StateChanged",
                         data: ["folder": "f1", "from": "idle", "to": "scanning"])
        server.pushEvent(type: "StateChanged",
                         data: ["folder": "f1", "from": "scanning", "to": "idle",
                                "duration": 35])
        server.pushEvent(type: "StateChanged",
                         data: ["folder": "f1", "from": "idle", "to": "error", "duration": 3])
        try await expectEventually { daemonRows(feed).count == 1 }
        #expect(daemonRows(feed)[0].kind == .folderError("folder path missing"))
        #expect(server.requestedPaths.filter { $0.contains("/rest/db/status") }.count == 1)

        server.pushEvent(type: "FolderWatchStateChanged",
                         data: ["folder": "f1", "to": "too many open files"])
        server.pushEvent(type: "FolderWatchStateChanged",
                         data: ["folder": "f1", "from": "too many open files"])
        try await expectEventually { daemonRows(feed).count == 3 }
        #expect(daemonRows(feed)[1].kind == .watchFailed("too many open files"))
        #expect(daemonRows(feed)[0].kind == .watchRestored)
    }

    // MARK: Clear & cost bounds

    /// Clear empties the log with no marker and flushes the open loops (a
    /// later catch-up confirms nothing the user removed), while a running
    /// loop keeps running — no restart, new activity appends as before.
    @Test func clearEmptiesLogAndFlushesLoopsWithoutRestart() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.activity.count == 1 }

        feed.clear()
        #expect(feed.entries.isEmpty)

        pushFullCatchUp(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "marker", "action": "modified"])
        try await expectEventually { feed.activity.contains { $0.path == "marker" } }
        #expect(feed.entries.count == 1)
        #expect(!feed.entries.contains { $0.kind == .delivered })
        #expect(loopStartCount(server) == 1)
    }

    /// The transfer-end availability reads are budgeted per wake: a burst
    /// of ended transfers resolves 20 on the wake that saw them and the
    /// rest on later wakes — never a fan-out of concurrent reads — and
    /// every one still gets its delivered entry.
    @Test func deliveryChecksAreBudgetedPerWake() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let paths = (1...30).map { "file-\($0).bin" }
        for path in paths {
            server.setFileAvailability(folder: "f1", path: path, devices: ["REMOTE7-FULL-ID"])
        }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)

        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": Dictionary(uniqueKeysWithValues: paths.map { ($0, 1) })])
        try await expectEventually { feed.activity.count == 30 }
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": [String: Int]()])

        func fileReads() -> Int {
            server.requestedPaths.filter { $0.contains("/rest/db/file") }.count
        }
        try await expectEventually { fileReads() == 20 }   // the first wake's budget
        try await expectEventually { fileReads() == 30 }   // the next wake's remainder
        try await expectEventually {
            feed.activity.filter { $0.kind == .delivered }.count == 30
        }
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

extension ActivityFeed {
    /// The log's SYNC FACTS — every entry except the lifecycle markers.
    /// The scenario tests assert on activity; the marker tests read
    /// `entries` directly.
    var activity: [Entry] { entries.filter { !$0.kind.isMarker } }
}
