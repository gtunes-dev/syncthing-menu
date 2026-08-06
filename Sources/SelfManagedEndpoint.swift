import Foundation

/// Turns the user's typed port into the base-URL form the REST client needs.
/// Self-managed is scoped to local instances, so the host is always loopback —
/// the literal 127.0.0.1 (not "localhost", which can resolve to ::1 and miss a
/// daemon bound to IPv4 loopback). This also reaches a daemon bound to
/// 0.0.0.0; the one thing it can't is a GUI bound exclusively to a
/// non-loopback interface — accepted until remote support exists.
enum SelfManagedEndpoint {
    /// Syncthing's default GUI port — the field's pre-fill and its fallback.
    static let defaultPort = 8384
    static let host = "127.0.0.1"

    /// Parse the port field: empty falls back to the default (the field's
    /// placeholder shows exactly that value, so the fallback is what the UI
    /// promises); anything else must be a whole number in port range.
    static func port(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultPort }
        guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
        return port
    }

    /// The base URL for a port field value, or nil when it isn't usable.
    static func guiURL(portText: String) -> String? {
        port(from: portText).map { "http://\(host):\($0)" }
    }
}

/// The session's discovery source in self-managed mode: the endpoint is
/// whatever the user entered in Settings, re-read on every connect attempt so
/// field edits are picked up by the running reconcile loop. Returns nil until
/// the fields hold usable values ("not configured" — the loop just keeps
/// waiting, which is the correct behavior).
final class SelfManagedEndpointSource: EndpointSource {
    private let settings: DaemonModeSettings

    init(settings: DaemonModeSettings) {
        self.settings = settings
    }

    var isConfigured: Bool { endpoint != nil }

    private var endpoint: SyncthingProcess.Endpoint? {
        let key = settings.selfManagedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              let url = SelfManagedEndpoint.guiURL(portText: settings.selfManagedPort) else {
            return nil
        }
        return SyncthingProcess.Endpoint(guiURL: url, apiKey: key)
    }

    func refreshEndpoint() throws -> SyncthingProcess.Endpoint? {
        endpoint
    }
}
