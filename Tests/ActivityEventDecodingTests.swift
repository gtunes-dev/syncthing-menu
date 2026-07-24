import Foundation
import Testing
@testable import SyncthingMenu

/// Decoding tests for the activity stream's flattened event shape — the
/// naming splits it papers over (item vs path, update/delete vs
/// modified/deleted, the RemoteDownloadProgress state map) and the
/// nanosecond-timestamp handling.
struct ActivityEventDecodingTests {

    private func decode(_ json: [String: Any]) throws -> SyncthingAPI.ActivityEvent {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SyncthingAPI.ActivityEvent.self, from: data)
    }

    /// Item events carry the path as `item` with update/metadata/delete actions.
    @Test func itemEventFlattensItemField() throws {
        let event = try decode([
            "id": 7, "type": "ItemStarted", "time": "2026-07-23T10:00:00Z",
            "data": ["folder": "f1", "item": "sub/a.txt", "action": "update", "type": "file"],
        ])
        #expect(event.id == 7)
        #expect(event.folder == "f1")
        #expect(event.path == "sub/a.txt")
        #expect(event.action == "update")
        #expect(event.itemKind == "file")
        #expect(event.modifiedBy == nil)
    }

    /// Disk-change events carry the path as `path`, plus label and modifiedBy.
    @Test func diskEventFlattensPathAndAttribution() throws {
        let event = try decode([
            "id": 8, "type": "RemoteChangeDetected", "time": "2026-07-23T10:00:00Z",
            "data": ["folder": "f1", "label": "Photos", "path": "b.heic",
                     "action": "deleted", "type": "file", "modifiedBy": "REMOTE7"],
        ])
        #expect(event.label == "Photos")
        #expect(event.path == "b.heic")
        #expect(event.action == "deleted")
        #expect(event.modifiedBy == "REMOTE7")
    }

    @Test func localIndexUpdatedCarriesBatchAndSequence() throws {
        let event = try decode([
            "id": 9, "type": "LocalIndexUpdated", "time": "2026-07-23T10:00:00Z",
            "data": ["folder": "f1", "filenames": ["a.txt", "b.txt"], "sequence": 4242],
        ])
        #expect(event.filenames == ["a.txt", "b.txt"])
        #expect(event.sequence == 4242)
    }

    @Test func folderCompletionCarriesWatermarkFields() throws {
        let event = try decode([
            "id": 10, "type": "FolderCompletion", "time": "2026-07-23T10:00:00Z",
            "data": ["folder": "f1", "device": "REMOTE7-FULL-ID", "completion": 100,
                     "needItems": 0, "sequence": 4242],
        ])
        #expect(event.device == "REMOTE7-FULL-ID")
        #expect(event.completion == 100)
        #expect(event.needItems == 0)
        #expect(event.sequence == 4242)
    }

    /// The `state` block-count map flattens to just its keys — the paths a
    /// remote is actively downloading.
    @Test func remoteDownloadProgressFlattensStateKeys() throws {
        let event = try decode([
            "id": 11, "type": "RemoteDownloadProgress", "time": "2026-07-23T10:00:00Z",
            "data": ["folder": "f1", "device": "REMOTE7-FULL-ID",
                     "state": ["big.mov": 12, "other.bin": 3]],
        ])
        #expect(Set(event.downloadingPaths ?? []) == ["big.mov", "other.bin"])
    }

    /// The daemon emits RFC 3339 with nanosecond fractions; parsing trims to
    /// milliseconds rather than failing.
    @Test func nanosecondTimestampParses() throws {
        let event = try decode([
            "id": 12, "type": "ItemFinished", "time": "2026-07-23T01:02:03.123456789Z",
            "data": ["folder": "f1", "item": "a.txt", "action": "update"],
        ])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2026-07-23T01:02:03.123Z")!
        #expect(abs(event.time.timeIntervalSince(expected)) < 0.001)
    }

    /// An unparseable timestamp falls back to the receive time, not a crash
    /// or a distant-past sentinel.
    @Test func garbageTimestampFallsBackToNow() throws {
        let event = try decode([
            "id": 13, "type": "ItemFinished", "time": "not-a-date",
            "data": ["folder": "f1", "item": "a.txt", "action": "update"],
        ])
        #expect(abs(event.time.timeIntervalSinceNow) < 5)
    }

    /// Events without a payload (or with unknown shapes) decode with nil
    /// fields rather than throwing — one odd event must not kill a batch.
    @Test func missingDataDecodesToNilFields() throws {
        let event = try decode(["id": 14, "type": "ConfigSaved",
                                "time": "2026-07-23T10:00:00Z"])
        #expect(event.folder == nil)
        #expect(event.path == nil)
        #expect(event.downloadingPaths == nil)
    }

    /// Device decoding tolerates the name field's presence, absence, and
    /// emptiness (the feed falls back to the short id for display).
    @Test func deviceNameDecodingVariants() throws {
        func device(_ json: [String: Any]) throws -> SyncthingAPI.Device {
            try JSONDecoder().decode(SyncthingAPI.Device.self,
                                     from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try device(["deviceID": "A", "paused": false, "name": "Laptop"]).name == "Laptop")
        #expect(try device(["deviceID": "A", "paused": false]).name == nil)
        #expect(try device(["deviceID": "A", "paused": false, "name": ""]).name == "")
    }
}
