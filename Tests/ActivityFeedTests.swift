import Foundation
import Testing
@testable import SyncthingMenu

/// Scenario tests for the activity log against the fake daemon: entry
/// creation from witnessed events, the same-batch collapse, author
/// enrichment, the opens-empty/drops-on-close lifecycle, the Devices panel,
/// and the polls-only-while-visible contract.
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
        try await expectEventually { feed.entries.count == 2 }

        #expect(feed.entries[0].path == "b.txt")
        #expect(feed.entries[0].operation == .deleted)
        #expect(feed.entries[1].path == "a.txt")
        #expect(feed.entries[1].operation == .modified)
        #expect(feed.entries.allSatisfy {
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
        try await expectEventually { feed.entries.count == 1 }
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 2 }

        #expect(feed.entries.allSatisfy { $0.kind == .detected && $0.path == "a.txt" })
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
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].kind == .sending)
        #expect(feed.entries[0].path == "unseen.bin")
        #expect(feed.entries[0].partyDisplay == "Laptop")
        #expect(feed.entries[0].folderLabel == "Folder One")

        // Same set again (the ~5s cadence): no new entries. Marker proves
        // the batch was processed.
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": ["unseen.bin": 7]])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 2 }
        #expect(feed.entries.filter { $0.kind == .sending }.count == 1)
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
        try await expectEventually { feed.entries.count == 1 }

        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": [String: Int]()])
        try await expectEventually {
            feed.entries.first?.kind == .delivered
        }
        #expect(feed.entries.count == 2)
        #expect(feed.entries[0].partyDisplay == "Laptop")
        #expect(feed.entries[1].kind == .sending)
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
        try await expectEventually { feed.entries.count == 1 }
        server.pushEvent(type: "RemoteDownloadProgress",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "state": [String: Int]()])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 2 }
        #expect(!feed.entries.contains { $0.kind == .delivered })
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
        try await expectEventually { feed.entries.count == 2 }

        // The peer still needs b.txt; a.txt is absent — delivered. The
        // delete stays tracked (tombstones need delivering too).
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID", names: ["b.txt"])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 50, "needItems": 1])
        try await expectEventually {
            feed.entries.contains {
                $0.kind == .delivered && $0.path == "a.txt" && $0.partyDisplay == "Laptop"
            }
        }
        #expect(!feed.entries.contains { $0.kind == .delivered && $0.path == "b.txt" })
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
            feed.entries.contains { $0.kind == .delivered && $0.path == "b.txt" }
        }
        #expect(feed.entries.first { $0.kind == .delivered && $0.path == "b.txt" }?
            .operation == .deleted)
        let after = needQueries()
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 90, "needItems": 1])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "x", "action": "modified"])
        try await expectEventually { feed.entries.contains { $0.path == "x" } }
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
        try await expectEventually { feed.entries.count == 1 }

        // files.count == perpage → the page is full; a.txt's absence from it
        // is meaningless.
        server.setRemoteNeed(folder: "f1", device: "REMOTE7-FULL-ID",
                             names: ["other.txt"], perpage: 1)
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 50, "needItems": 1])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 2 }
        #expect(!feed.entries.contains { $0.kind == .delivered })
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
        try await expectEventually { feed.entries.count == 3 }

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually { feed.entries.count == 6 }
        let delivered = feed.entries.filter { $0.kind == .delivered }
        #expect(Set(delivered.map(\.path)) == ["a.txt", "b.txt", "c.txt"])
        #expect(delivered.allSatisfy { $0.partyDisplay == "Laptop" })
        // The delete's delivery carries its operation (tombstone delivered).
        #expect(delivered.first { $0.path == "c.txt" }?.operation == .deleted)

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "OTHER", "path": "marker", "action": "modified"])
        try await expectEventually { feed.entries.contains { $0.path == "marker" } }
        #expect(feed.entries.filter { $0.kind == .delivered }.count == 3)
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
            feed.entries.filter { $0.kind == .delivered && $0.path == "churn.plist" }.count
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
        try await expectEventually { feed.entries.contains { $0.path == "marker1.txt" } }
        #expect(deliveredCount() == 1)

        // Episode 2: the file churns again — its new delivery logs again.
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "churn.plist", "action": "modified"])
        try await expectEventually {
            feed.entries.first { $0.path == "churn.plist" }?.kind == .detected
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
        try await expectEventually { feed.entries.count == 1 }

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 2])
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "SELF",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 2 }
        #expect(!feed.entries.contains { $0.kind == .delivered })
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

        let burst = (1...30).map { index in
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "churn/file\(index).dat",
                    "action": "modified"] as [String: Any])
        }
        server.pushEvents(burst)
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].kind == .detected)
        #expect(feed.entries[0].bulkCount == 30)
        #expect(feed.entries[0].displayName == "30 changes")
        #expect(feed.entries[0].partyDisplay == "This Mac")
        #expect(feed.entries[0].folderLabel == "Folder One")

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually { feed.entries.first?.kind == .delivered }
        #expect(feed.entries.first?.bulkCount == 30)
        #expect(feed.entries.first?.partyDisplay == "Laptop")
        #expect(feed.entries.count == 2)
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
        try await expectEventually { feed.entries.count == 1 }

        // The index batch covers three items; we witnessed one — the other
        // two are recovered by name, not aggregated.
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": 3,
                                "filenames": ["seen.txt", "ghost1.txt", "ghost2.txt"]])
        try await expectEventually { feed.entries.count == 3 }
        for ghost in ["ghost1.txt", "ghost2.txt"] {
            let entry = feed.entries.first { $0.path == ghost }
            #expect(entry?.kind == .detected)
            #expect(entry?.bulkCount == nil)
            #expect(entry?.partyDisplay == "This Mac")
        }
        #expect(feed.entries.filter { $0.path == "seen.txt" }.count == 1)   // no duplicate

        // Recovered loops close per-item on catch-up.
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually {
            feed.entries.contains { $0.kind == .delivered && $0.path == "ghost1.txt" }
        }
        #expect(!feed.entries.contains { $0.bulkCount != nil })
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
        try await expectEventually { feed.entries.contains { $0.path == "marker.txt" } }
        #expect(feed.entries.filter { $0.path == "a.txt" }.count == 1)
        #expect(feed.entries.filter { $0.path == "b.txt" }.count == 1)
        #expect(feed.entries.count == 3)

        // The marker is consumed: a real second change logs normally.
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified"])
        try await expectEventually {
            feed.entries.filter { $0.path == "a.txt" }.count == 2
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
        try await expectEventually { feed.entries.contains { $0.path == "marker.txt" } }
        let detected = feed.entries.filter { $0.path == "gone.txt" }
        #expect(detected.count == 1)
        #expect(detected.first?.operation == .deleted)

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually {
            feed.entries.contains { $0.kind == .delivered && $0.path == "gone.txt" }
        }
        #expect(feed.entries.first {
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
        try await expectEventually { feed.entries.contains { $0.path == "marker.txt" } }
        #expect(feed.entries.count == 1)

        // Large surplus with truncated filenames (count != items): the
        // count is real churn scale — one bulk entry, closed in bulk.
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": 60,
                                "filenames": ["partial1.txt", "partial2.txt"]])
        try await expectEventually {
            // 60 items minus the one witnessed marker = 59 unwitnessed.
            feed.entries.contains { $0.kind == .detected && $0.bulkCount == 59 }
        }

        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        try await expectEventually {
            feed.entries.contains { $0.kind == .delivered && $0.bulkCount == 59 }
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
        try await expectEventually { feed.entries.count == 1 }

        // Fresh loop: wakes come and go (the fake's parks cycle fast), but
        // no probe is issued below the staleness threshold.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!server.requestedPaths.contains { $0.contains("/rest/db/completion") })

        // NO FolderCompletion ever arrives (the missed-cue scenario). Going
        // stale, the next wake probes completion and closes the loop.
        currentTime = currentTime.addingTimeInterval(31)
        try await expectEventually { feed.entries.first?.kind == .delivered }
        #expect(feed.entries.first?.path == "a.txt")
        #expect(feed.entries.first?.partyDisplay == "Laptop")
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
        try await expectEventually { feed.entries.count == 2 }

        currentTime = currentTime.addingTimeInterval(31)
        try await expectEventually {
            feed.entries.contains { $0.kind == .delivered && $0.path == "a.txt" }
        }
        #expect(!feed.entries.contains {
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
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].kind == .detected)

        // The remote reads fully caught up — but nothing was promised, so
        // nothing "delivers" (marker proves the batch processed).
        server.pushEvent(type: "FolderCompletion",
                         data: ["folder": "f1", "device": "REMOTE7-FULL-ID",
                                "completion": 100, "needItems": 0, "needDeletes": 0])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "marker.txt", "action": "modified"])
        try await expectEventually { feed.entries.contains { $0.path == "marker.txt" } }
        #expect(!feed.entries.contains { $0.kind == .delivered })
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
        try await expectEventually { feed.entries.count == 1 }

        currentTime = currentTime.addingTimeInterval(31)
        try await Task.sleep(nanoseconds: 400_000_000)   // several empty wakes
        #expect(!server.requestedPaths.contains { $0.contains("/rest/db/completion") })
        #expect(!feed.entries.contains { $0.kind == .delivered })
        #expect(feed.entries.first?.kind == .detected)
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
            feed.entries.first { $0.path == "y.txt" }?.folderLabel == "Renamed"
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
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].kind == .applied)
        #expect(feed.entries[0].partyDisplay == "—")   // author unknown until the commit event
        #expect(feed.entries[0].folderLabel == "Folder One")
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
        try await expectEventually { feed.entries.first?.kind == .downloading }

        server.pushEvent(type: "ItemFinished",
                         data: ["folder": "f1", "item": "big.mov", "action": "update"])
        try await expectEventually { feed.entries.count == 2 }
        #expect(feed.entries[0].kind == .applied)
        #expect(feed.entries[1].kind == .downloading)
        #expect(feed.entries.allSatisfy { $0.path == "big.mov" })
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
            feed.entries.first?.kind == .failed("permission denied")
        }
        #expect(feed.entries.count == 1)

        server.pushEvent(type: "ItemStarted",
                         data: ["folder": "f1", "item": "c.txt", "action": "update"])
        try await expectEventually { feed.entries.count == 2 }
        #expect(feed.entries[0].kind == .downloading)
        #expect(feed.entries[1].kind == .failed("permission denied"))
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
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].partyDisplay == "—")

        server.pushEvent(type: "RemoteChangeDetected",
                         data: ["folder": "f1", "path": "c.txt", "action": "modified",
                                "type": "file", "modifiedBy": "REMOTE7"])
        try await expectEventually { feed.entries.first?.partyDisplay == "Laptop" }
        #expect(feed.entries.count == 1)
        #expect(feed.entries[0].kind == .applied)
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
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].kind == .applied)
        #expect(feed.entries[0].operation == .deleted)
        #expect(feed.entries[0].partyDisplay == "Laptop")
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
        #expect(feed.entries.isEmpty)
        #expect(!server.requestedPaths.contains { $0.contains("db/remoteneed") })

        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "observed.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 1 }
        #expect(feed.entries[0].kind == .detected)
    }

    /// Closing drops the log; reopening starts empty — witnessed activity
    /// only, never a resurrected past.
    @Test func closingDropsEntriesAndReopenStartsEmpty() async throws {
        let server = try standardServer()
        defer { server.stop() }
        let feed = makeFeed()
        defer { feed.disconnect() }
        feed.connect(api: api(for: server))
        feed.setWindowVisible(true)
        try await waitUntilPolling(server)
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "seen.txt", "action": "modified"])
        try await expectEventually { feed.entries.count == 1 }

        feed.setWindowVisible(false)
        #expect(feed.entries.isEmpty)

        let polls = pollCount(server)
        feed.setWindowVisible(true)
        try await expectEventually { pollCount(server) > polls }
        #expect(feed.entries.isEmpty)
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
