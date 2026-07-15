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
    /// other fields in the response are ignored.
    struct Folder: Decodable, Equatable {
        let id: String
        let label: String
        let path: String
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
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw APIError.badURL
        }
        let data = try await send("/rest/db/status?folder=\(encoded)", method: "GET")
        return try JSONDecoder().decode(Response.self, from: data).state
    }

    // MARK: Devices

    /// One configured device. Decoded from `/rest/config/devices`; the local device
    /// appears in the list too — filter it out via `myID()` where it matters.
    struct Device: Decodable, Equatable {
        let deviceID: String
        let paused: Bool
    }

    /// `GET /rest/config/devices` → the configured devices (including this one).
    func devices() async throws -> [Device] {
        let data = try await send("/rest/config/devices", method: "GET")
        return try JSONDecoder().decode([Device].self, from: data)
    }

    // MARK: Events

    /// One event from `/rest/events`. The type-specific `data` payload is
    /// flattened to the fields we consume: StateChanged carries folder/to,
    /// DevicePaused/DeviceResumed carry device; anything else decodes with all
    /// three nil (ConfigSaved's payload — the whole new config — is ignored).
    struct Event: Decodable {
        let id: Int
        let type: String
        let folder: String?
        let to: String?
        let device: String?

        private enum CodingKeys: String, CodingKey { case id, type, data }
        private enum DataKeys: String, CodingKey { case folder, to, device }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            if let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
                folder = try? data.decodeIfPresent(String.self, forKey: .folder)
                to = try? data.decodeIfPresent(String.self, forKey: .to)
                device = try? data.decodeIfPresent(String.self, forKey: .device)
            } else {
                folder = nil; to = nil; device = nil
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
