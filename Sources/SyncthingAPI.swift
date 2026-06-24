import Foundation

/// A thin async client for the managed Syncthing daemon's REST API. Every request
/// authenticates with the daemon's API key via the `X-API-Key` header.
///
/// Endpoints and response shapes here are verified against a live v2.1.1 daemon.
struct SyncthingAPI {
    let baseURL: URL    // e.g. http://127.0.0.1:60533
    let apiKey: String

    enum APIError: Error, Equatable {
        case badURL
        case http(Int)
    }

    // MARK: System

    /// `GET /rest/system/version` → the running version, e.g. "v2.1.1".
    func systemVersion() async throws -> String {
        struct Response: Decodable { let version: String }
        let data = try await send("/rest/system/version", method: "GET")
        return try JSONDecoder().decode(Response.self, from: data).version
    }

    /// `GET /rest/system/upgrade` → upgrade availability. `newer` and `majorNewer`
    /// are mutually exclusive: Syncthing surfaces a pending minor before a major, so
    /// `majorNewer` only becomes true once no minor upgrade is pending.
    struct UpgradeInfo: Decodable, Equatable {
        let running: String
        let latest: String
        let newer: Bool
        let majorNewer: Bool
    }

    func upgradeInfo() async throws -> UpgradeInfo {
        let data = try await send("/rest/system/upgrade", method: "GET")
        return try JSONDecoder().decode(UpgradeInfo.self, from: data)
    }

    /// `POST /rest/system/upgrade` → upgrade to the latest available version and
    /// restart. Used only on explicit user consent (majors are always gated).
    func performUpgrade() async throws {
        _ = try await send("/rest/system/upgrade", method: "POST")
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

    // MARK: - Request plumbing

    private func send(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
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
