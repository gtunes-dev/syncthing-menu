import Foundation

/// A thin async client for the managed Syncthing daemon's REST API. Every request
/// authenticates with the daemon's API key via the `X-API-Key` header.
///
/// Endpoints and response shapes here are verified against a live v2.1.1 daemon.
/// Equatable by endpoint identity (base URL + key) — the session layer uses this
/// to tell a real endpoint change from a republish of the same one.
struct SyncthingAPI: Equatable {
    let baseURL: URL    // e.g. http://127.0.0.1:60533
    let apiKey: String

    enum APIError: Error, Equatable {
        case badURL
        case http(Int)
    }

    // MARK: System

    /// The running build, from `GET /rest/system/version`: version tag ("v2.1.1")
    /// and architecture (Go's `runtime.GOARCH`, e.g. "arm64" — which slice of the
    /// universal binary is running, needed to pick the right release asset).
    struct SystemVersion: Decodable, Equatable {
        let version: String
        let arch: String
    }

    func systemVersionInfo() async throws -> SystemVersion {
        let data = try await send("/rest/system/version", method: "GET")
        return try JSONDecoder().decode(SystemVersion.self, from: data)
    }

    /// The running version tag alone, e.g. "v2.1.1".
    func systemVersion() async throws -> String {
        try await systemVersionInfo().version
    }

    /// The daemon options the client-side upgrade check mirrors: which releases
    /// feed the daemon would install from, and whether prereleases count. Reading
    /// them from the daemon keeps our check and its `POST /rest/system/upgrade`
    /// resolving releases from identical inputs. (The daemon's own
    /// `GET /rest/system/upgrade` is disabled by `STNOUPGRADE` — see
    /// `SyncthingReleases`.)
    struct UpgradeCheckOptions: Decodable, Equatable {
        let releasesURL: String
        let upgradeToPreReleases: Bool
    }

    func upgradeCheckOptions() async throws -> UpgradeCheckOptions {
        let data = try await send("/rest/config/options", method: "GET")
        return try JSONDecoder().decode(UpgradeCheckOptions.self, from: data)
    }

    /// `POST /rest/system/upgrade` → upgrade to the latest available version and
    /// restart. Used only on explicit user consent (majors are always gated).
    /// Still served with `STNOUPGRADE` set (only the GET checks that flag —
    /// verified live on v2.1.1); if a future daemon closes that asymmetry this
    /// throws `.http(501)` and the install fails visibly.
    func performUpgrade() async throws {
        _ = try await send("/rest/system/upgrade", method: "POST")
    }

    /// `GET /rest/system/status` → this device's own ID (for filtering the local
    /// device out of the configured-devices list).
    func myID() async throws -> String {
        struct Response: Decodable { let myID: String }
        let data = try await send("/rest/system/status", method: "GET")
        return try JSONDecoder().decode(Response.self, from: data).myID
    }

    /// `POST /rest/system/pause` with no `device` parameter → pause all devices.
    func pauseAllDevices() async throws {
        _ = try await send("/rest/system/pause", method: "POST")
    }

    /// `POST /rest/system/resume` with no `device` parameter → resume all devices.
    func resumeAllDevices() async throws {
        _ = try await send("/rest/system/resume", method: "POST")
    }

    /// `POST /rest/system/shutdown` → ask the daemon to exit cleanly and not restart.
    /// Served by the worker (which owns the API); its clean exit takes the monitor down
    /// too. Our primary graceful stop; the process supervisor falls back to a signal if
    /// the daemon doesn't exit in time.
    func shutdown() async throws {
        _ = try await send("/rest/system/shutdown", method: "POST")
    }

    // MARK: Config

    /// `PATCH /rest/config/options` → set the daemon's auto-upgrade interval. We set
    /// it to 0 to disable the daemon's own self-upgrader (we own updates).
    func setAutoUpgradeIntervalH(_ hours: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["autoUpgradeIntervalH": hours])
        _ = try await send("/rest/config/options", method: "PATCH", body: body)
    }

    // MARK: Folders

    /// One configured sync folder. Decoded from `/rest/config/folders`; the many
    /// other fields in the response are ignored. `paused` matters beyond
    /// display: a paused folder is not running, and the per-folder endpoints
    /// (`/rest/folder/errors`) return 404 "folder is paused" for it —
    /// verified live 2026-08-03. `type` and `devices` feed the activity
    /// feed's delivery expectation: a receive-only folder never sends local
    /// changes, and the share list bounds who could receive them.
    struct Folder: Decodable, Equatable {
        struct SharedDevice: Decodable, Equatable {
            let deviceID: String
        }

        let id: String
        let label: String
        let path: String
        let paused: Bool
        /// "sendreceive" / "sendonly" / "receiveonly" (nil on responses that
        /// omit it — treated as the sendreceive default).
        let type: String?
        /// The devices this folder is shared with, INCLUDING this device.
        let devices: [SharedDevice]?
    }

    /// `GET /rest/config/folders` → the configured folders (id, label, filesystem path).
    func folders() async throws -> [Folder] {
        let data = try await send("/rest/config/folders", method: "GET")
        return try JSONDecoder().decode([Folder].self, from: data)
    }

    /// `POST /rest/db/scan` with no `folder` parameter → rescan all folders.
    func rescanAll() async throws {
        _ = try await send("/rest/db/scan", method: "POST")
    }

    /// `GET /rest/db/status?folder=` → the folder's current state ("idle",
    /// "scanning", "syncing", "scan-waiting", …). Seeds the monitor's activity
    /// snapshot at connect: the event subscription only reports changes from its
    /// creation onward, so current state must be read directly.
    func folderState(id: String) async throws -> String {
        struct Response: Decodable { let state: String }
        let data = try await send("/rest/db/status?folder=\(try Self.encodeQueryValue(id))",
                                  method: "GET")
        return try JSONDecoder().decode(Response.self, from: data).state
    }

    /// One path Syncthing couldn't process in a folder, with its error text.
    struct FolderError: Decodable, Equatable {
        let path: String
        let error: String
    }

    /// `GET /rest/folder/errors?folder=` → the folder's current scan/pull errors
    /// (empty when healthy). Seeds the monitor's folder-health view; the
    /// FolderErrors *event* carries the same shape but only fires when errors
    /// occur, so recovery must be observed by re-reading this.
    func folderErrors(id: String) async throws -> [FolderError] {
        struct Response: Decodable { let errors: [FolderError]? }
        let data = try await send("/rest/folder/errors?folder=\(try Self.encodeQueryValue(id))",
                                  method: "GET")
        return try JSONDecoder().decode(Response.self, from: data).errors ?? []
    }

    /// One page of a remote device's need list for a folder.
    struct RemoteNeed {
        /// Folder-relative paths the device still needs.
        let needed: Set<String>
        /// Whether `needed` is the complete list (the page wasn't full).
        /// Absence-based delivery inference is only sound when complete.
        let complete: Bool
    }

    /// Items fetched per `remoteNeed` page. One page bounds the query cost;
    /// a full page (a peer with a massive backlog) just defers per-file
    /// confirmation to the folder-level catch-up path.
    static let remoteNeedPageSize = 1000

    /// `GET /rest/db/remoteneed?folder=&device=` → what `device` still needs
    /// to be in sync with `folder`, computed from OUR index — our number
    /// space, so comparing our rows against it is sound (unlike
    /// FolderCompletion.sequence, which lives in the remote's own space).
    /// Drives the activity feed's per-file delivery confirmation.
    func remoteNeed(folder: String, device: String) async throws -> RemoteNeed {
        struct File: Decodable { let name: String }
        struct Response: Decodable {
            let files: [File]?
            let perpage: Int?
        }
        let query = "folder=\(try Self.encodeQueryValue(folder))"
            + "&device=\(try Self.encodeQueryValue(device))"
            + "&page=1&perpage=\(Self.remoteNeedPageSize)"
        let data = try await send("/rest/db/remoteneed?\(query)", method: "GET")
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let files = decoded.files ?? []
        return RemoteNeed(needed: Set(files.map(\.name)),
                          complete: files.count < (decoded.perpage ?? Self.remoteNeedPageSize))
    }

    /// One file's index entry, as the activity feed needs it: authorship and
    /// current availability.
    struct FileStatus: Equatable {
        /// The short device id from the global entry's version, nil if absent.
        let modifiedBy: String?
        /// Full ids of the devices the file is currently available from —
        /// for an outbound file, the remotes that already HAVE it. Computed
        /// from our own index, so a per-file delivery check against it is
        /// sound regardless of how large the folder's need list is.
        let availableOn: [String]
    }

    /// `GET /rest/db/file` → authorship + availability for one path. Used by
    /// the activity feed to resolve rows whose triggering signal names only
    /// the path (transfer mentions, truth-seeded queue rows), and to settle
    /// in-flight rows whose transfer ended without a witnessed confirmation.
    func fileStatus(folder: String, file: String) async throws -> FileStatus {
        struct Info: Decodable { let modifiedBy: String? }
        struct Availability: Decodable { let id: String }
        struct Response: Decodable {
            let global: Info?
            let availability: [Availability]?
        }
        let query = "folder=\(try Self.encodeQueryValue(folder))"
            + "&file=\(try Self.encodeQueryValue(file))"
        let data = try await send("/rest/db/file?\(query)", method: "GET")
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return FileStatus(modifiedBy: decoded.global?.modifiedBy,
                          availableOn: (decoded.availability ?? []).map(\.id))
    }

    private static func encodeQueryValue(_ value: String) throws -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw APIError.badURL
        }
        return encoded
    }

    // MARK: Devices

    /// One configured device. Decoded from `/rest/config/devices`; the local device
    /// appears in the list too — filter it out via `myID()` where it matters.
    /// `name` is the user-assigned display name (may be empty).
    struct Device: Decodable, Equatable {
        let deviceID: String
        let paused: Bool
        var name: String? = nil
    }

    /// `GET /rest/config/devices` → the configured devices (including this one).
    func devices() async throws -> [Device] {
        let data = try await send("/rest/config/devices", method: "GET")
        return try JSONDecoder().decode([Device].self, from: data)
    }

    /// `GET /rest/system/connections` → the ids of the remote devices currently
    /// connected. Seeds the monitor's outbound-transfer view at connect; live
    /// changes arrive as DeviceConnected/DeviceDisconnected events.
    func connectedDevices() async throws -> Set<String> {
        struct Connection: Decodable { let connected: Bool }
        struct Response: Decodable { let connections: [String: Connection] }
        let data = try await send("/rest/system/connections", method: "GET")
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Set(decoded.connections.filter(\.value.connected).map(\.key))
    }

    // MARK: Events

    /// One event from `/rest/events`. The type-specific `data` payload is
    /// flattened to the fields we consume: StateChanged carries folder/to,
    /// DevicePaused/DeviceResumed/DeviceConnected/DeviceDisconnected carry
    /// device, FolderErrors carries folder/errors, FolderCompletion carries
    /// device/folder/completion/needItems/needDeletes; anything else decodes
    /// with all fields nil (ConfigSaved's payload — the whole new config — is
    /// ignored).
    struct Event: Decodable {
        let id: Int
        let type: String
        let folder: String?
        let to: String?
        let device: String?
        let errors: [FolderError]?
        let completion: Double?
        let needItems: Int?
        let needDeletes: Int?

        private enum CodingKeys: String, CodingKey { case id, type, data }
        private enum DataKeys: String, CodingKey {
            case folder, to, device, errors, completion, needItems, needDeletes
            /// DeviceConnected/DeviceDisconnected name the device `id` where
            /// DevicePaused/DeviceResumed/FolderCompletion say `device` —
            /// an upstream inconsistency; `device` is decoded from either.
            case deviceId = "id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            if let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
                folder = try? data.decodeIfPresent(String.self, forKey: .folder)
                to = try? data.decodeIfPresent(String.self, forKey: .to)
                device = (try? data.decodeIfPresent(String.self, forKey: .device))
                    ?? (try? data.decodeIfPresent(String.self, forKey: .deviceId))
                errors = try? data.decodeIfPresent([FolderError].self, forKey: .errors)
                completion = try? data.decodeIfPresent(Double.self, forKey: .completion)
                needItems = try? data.decodeIfPresent(Int.self, forKey: .needItems)
                needDeletes = try? data.decodeIfPresent(Int.self, forKey: .needDeletes)
            } else {
                folder = nil; to = nil; device = nil; errors = nil
                completion = nil; needItems = nil; needDeletes = nil
            }
        }
    }

    /// `GET /rest/events` — long-poll. Blocks server-side until a matching event
    /// occurs or `timeout` seconds pass (then returns an empty batch). The
    /// URLRequest's own timeout is padded past the server's so the server side
    /// always wins.
    ///
    /// VERIFIED against a live v2 daemon: a filtered call creates its
    /// subscription on FIRST use and buffers only events from that moment on
    /// (`since=0` replays that subscription's buffer, not the daemon's whole
    /// history), and event `id`s are per-subscription (the daemon-wide sequence
    /// is `globalID`, which we don't use). `limit=N` returns the newest N.
    func events(since: Int, types: [String], timeout: Int, limit: Int? = nil) async throws -> [Event] {
        var query = "since=\(since)&timeout=\(timeout)&events=\(types.joined(separator: ","))"
        if let limit { query += "&limit=\(limit)" }
        let data = try await send("/rest/events?\(query)", method: "GET",
                                  timeoutInterval: TimeInterval(timeout + 10))
        return try JSONDecoder().decode([Event].self, from: data)
    }

    /// One event from the activity stream (`ActivityFeed`), decoded to a
    /// common flattened shape. Field naming differs per type —
    /// ItemStarted/ItemFinished carry the path as `item` with `action`
    /// update/metadata/delete; the disk-change events carry it as `path` with
    /// `action` modified/deleted plus `label` and `modifiedBy` (the short id
    /// of the device that originated the change). FolderCompletion carries
    /// `device`, `completion`, `needItems` (per remote device).
    struct ActivityEvent: Decodable {
        let id: Int
        let type: String
        /// The daemon's per-event wall-clock timestamp; falls back to the
        /// receive time if it fails to parse.
        let time: Date
        let folder: String?
        let label: String?
        let path: String?
        let action: String?
        let itemKind: String?    // "file" / "dir" / "symlink"
        let modifiedBy: String?
        let error: String?
        let device: String?
        let completion: Double?
        let needItems: Int?
        let needDeletes: Int?
        /// LocalIndexUpdated: how many index items the batched event covers —
        /// the activity feed's burst backstop (batched events survive the
        /// ring overflow that eats per-file change events).
        let items: Int?
        /// LocalIndexUpdated: the batch's file names. Complete when its
        /// count equals `items` — then the backstop can recover missed
        /// changes BY NAME instead of aggregating.
        let filenames: [String]?
        /// RemoteDownloadProgress: the paths the remote device is actively
        /// downloading (the keys of its `state` block-count map).
        let downloadingPaths: [String]?

        private enum CodingKeys: String, CodingKey { case id, type, time, data }
        private enum DataKeys: String, CodingKey {
            case folder, label, path, item, action, type, modifiedBy, error
            case device, completion, needItems, needDeletes, items, filenames, state
            // DeviceConnected/DeviceDisconnected carry the device id as `id`
            // while every other device-bearing event says `device` (upstream
            // inconsistency, docs-verified 2026-08-02) — decode both.
            case deviceID = "id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            time = Self.parseTime(try? container.decode(String.self, forKey: .time))
            if let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
                folder = try? data.decodeIfPresent(String.self, forKey: .folder)
                label = try? data.decodeIfPresent(String.self, forKey: .label)
                path = (try? data.decodeIfPresent(String.self, forKey: .path))
                    ?? (try? data.decodeIfPresent(String.self, forKey: .item))
                action = try? data.decodeIfPresent(String.self, forKey: .action)
                itemKind = try? data.decodeIfPresent(String.self, forKey: .type)
                modifiedBy = try? data.decodeIfPresent(String.self, forKey: .modifiedBy)
                error = try? data.decodeIfPresent(String.self, forKey: .error)
                device = (try? data.decodeIfPresent(String.self, forKey: .device))
                    ?? (try? data.decodeIfPresent(String.self, forKey: .deviceID))
                completion = try? data.decodeIfPresent(Double.self, forKey: .completion)
                needItems = try? data.decodeIfPresent(Int.self, forKey: .needItems)
                needDeletes = try? data.decodeIfPresent(Int.self, forKey: .needDeletes)
                items = try? data.decodeIfPresent(Int.self, forKey: .items)
                filenames = try? data.decodeIfPresent([String].self, forKey: .filenames)
                downloadingPaths = (try? data.decodeIfPresent([String: Int].self, forKey: .state))
                    .map { Array($0.keys) }
            } else {
                folder = nil; label = nil; path = nil; action = nil
                itemKind = nil; modifiedBy = nil; error = nil
                device = nil; completion = nil; needItems = nil
                needDeletes = nil; items = nil; filenames = nil
                downloadingPaths = nil
            }
        }

        private static let isoWithFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let isoPlain = ISO8601DateFormatter()

        /// The daemon emits RFC 3339 with nanosecond fractions;
        /// `ISO8601DateFormatter` only accepts millisecond fractions, so trim
        /// the excess digits before parsing.
        private static func parseTime(_ raw: String?) -> Date {
            guard let raw else { return Date() }
            let trimmed = raw.replacingOccurrences(of: #"(\.\d{1,3})\d*"#, with: "$1",
                                                   options: .regularExpression)
            return isoWithFraction.date(from: trimmed)
                ?? isoPlain.date(from: raw)
                ?? Date()
        }
    }

    /// The activity stream — long-poll semantics identical to `events`, but a
    /// distinct filter (thus a distinct server-side subscription) decoding the
    /// richer change-lifecycle payloads. The disk-change events must be named
    /// explicitly: they are excluded from the default event mask. Every type
    /// has a consumer in `ActivityFeed`: the change/item events drive log
    /// entries, FolderCompletion drives delivery confirmation + Devices-panel
    /// counts, RemoteDownloadProgress is the per-item outbound signal,
    /// LocalIndexUpdated is the burst backstop, ConfigSaved cues an identity
    /// refresh, and the connectivity pair maintains the connected set.
    static let activityEventTypes = ["LocalChangeDetected", "RemoteChangeDetected",
                                     "ItemStarted", "ItemFinished",
                                     "FolderCompletion", "RemoteDownloadProgress",
                                     "LocalIndexUpdated", "ConfigSaved",
                                     "DeviceConnected", "DeviceDisconnected"]

    func activityEvents(since: Int, timeout: Int, limit: Int? = nil) async throws -> [ActivityEvent] {
        var query = "since=\(since)&timeout=\(timeout)&events=\(Self.activityEventTypes.joined(separator: ","))"
        if let limit { query += "&limit=\(limit)" }
        let data = try await send("/rest/events?\(query)", method: "GET",
                                  timeoutInterval: TimeInterval(timeout + 10))
        return try JSONDecoder().decode([ActivityEvent].self, from: data)
    }

    /// One device's sync position for one folder, computed from OUR index —
    /// the same numbers FolderCompletion events carry. Works for the local
    /// device too (pass `myID`): then it's this device's completion against
    /// the global state (the inbound backlog).
    struct Completion: Decodable, Equatable {
        let completion: Double
        let needItems: Int
        let needDeletes: Int
    }

    /// `GET /rest/db/completion?folder=&device=` → that device's position for
    /// the folder. Fails (404) for a device that doesn't share the folder —
    /// callers use that to discover sharing.
    func completion(folder: String, device: String) async throws -> Completion {
        let query = "folder=\(try Self.encodeQueryValue(folder))"
            + "&device=\(try Self.encodeQueryValue(device))"
        let data = try await send("/rest/db/completion?\(query)", method: "GET")
        return try JSONDecoder().decode(Completion.self, from: data)
    }

    // MARK: - Request plumbing

    private func send(_ path: String, method: String, body: Data? = nil,
                      timeoutInterval: TimeInterval? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        return data
    }
}
