import Foundation
import Network

/// An in-process fake of the Syncthing REST endpoints the app consumes, listening
/// on a real localhost socket so the failure modes under test are transport-real:
/// connection refused (listener stopped), 403 (rotated API key), 500 (scripted
/// flakiness). Scriptable per test — rotate the accepted key, fail the next N
/// requests, push events into a parked long-poll, stop the listener entirely.
///
/// Response *shapes* mirror what `SyncthingAPI` expects (those were verified
/// against a live daemon); this fake scripts *availability and change*, it does
/// not re-verify the protocol. Long-poll parks are capped at 0.25s so idle polls
/// cycle fast under test.
final class FakeSyncthingServer {

    struct Device {
        var deviceID: String
        var paused: Bool
    }

    struct Folder {
        var id: String
        var label = ""
        var path = "/tmp"
        var state = "idle"
        /// Current scan/pull errors, served by /rest/folder/errors.
        var errors: [(path: String, error: String)] = []
    }

    // MARK: - Scriptable state (all access serialized on `queue`)

    private let queue = DispatchQueue(label: "FakeSyncthingServer")
    private var _apiKey: String
    private var _versionTag = "v2.1.2"
    private var _myID = "SELF"
    private var _devices: [Device] = []
    private var _folders: [Folder] = []
    private var _failNextRequests = 0
    private var _recordedAutoUpgradeIntervals: [Int] = []

    private var events: [(id: Int, json: [String: Any])] = []
    private var nextEventID = 1

    private final class Waiter {
        let since: Int
        let respond: ([[String: Any]]) -> Void
        var timer: DispatchSourceTimer?
        init(since: Int, respond: @escaping ([[String: Any]]) -> Void) {
            self.since = since
            self.respond = respond
        }
    }
    private var waiters: [Waiter] = []

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    private(set) var port: UInt16 = 0
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(apiKey: String = "test-key") {
        _apiKey = apiKey
    }

    /// The API key the server accepts. Reassigning models a Web-UI key rotation:
    /// requests carrying the old key get 403 from that moment on.
    var apiKey: String {
        get { queue.sync { _apiKey } }
        set { queue.sync { _apiKey = newValue } }
    }

    var versionTag: String {
        get { queue.sync { _versionTag } }
        set { queue.sync { _versionTag = newValue } }
    }

    var myID: String {
        get { queue.sync { _myID } }
        set { queue.sync { _myID = newValue } }
    }

    var devices: [Device] {
        get { queue.sync { _devices } }
        set { queue.sync { _devices = newValue } }
    }

    var folders: [Folder] {
        get { queue.sync { _folders } }
        set { queue.sync { _folders = newValue } }
    }

    /// Fail this many upcoming requests with a 500 (any endpoint), then recover.
    var failNextRequests: Int {
        get { queue.sync { _failNextRequests } }
        set { queue.sync { _failNextRequests = newValue } }
    }

    /// Every `autoUpgradeIntervalH` value PATCHed to /rest/config/options, in
    /// order — lets tests assert the no-self-upgrade invariant was (re)applied.
    var recordedAutoUpgradeIntervals: [Int] {
        queue.sync { _recordedAutoUpgradeIntervals }
    }

    // MARK: - Lifecycle

    /// Start listening on an OS-assigned localhost port; `baseURL` is valid after
    /// this returns.
    func start() throws {
        let listener = try NWListener(using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue, port > 0 else {
            throw NSError(domain: "FakeSyncthingServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener failed to become ready"])
        }
        self.port = port
    }

    /// Stop listening and drop every connection. Subsequent requests to `baseURL`
    /// are refused — the "endpoint went dark / moved" simulation.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections = []
            waiters.forEach { $0.timer?.cancel() }
            waiters = []
        }
    }

    /// Append an event (ids are 1-based and monotonic, like a fresh daemon
    /// subscription) and release any parked long-poll that should see it.
    func pushEvent(type: String, data: [String: Any] = [:]) {
        queue.sync {
            let id = nextEventID
            nextEventID += 1
            events.append((id: id, json: [
                "id": id, "globalID": id, "type": type,
                "time": "2026-01-01T00:00:00Z", "data": data,
            ]))
            let parked = waiters
            waiters = []
            for waiter in parked {
                waiter.timer?.cancel()
                waiter.respond(events.filter { $0.id > waiter.since }.map(\.json))
            }
        }
    }

    // MARK: - Connection handling (on `queue`)

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]   // keys lowercased
        var body: Data
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.handle(request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: buffer)
            }
        }
    }

    /// Parse one HTTP/1.1 request; nil if the buffer doesn't yet hold the full
    /// head + declared body.
    private static func parse(_ buffer: Data) -> Request? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let body = buffer[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return Request(method: requestLine[0], path: requestLine[1],
                       headers: headers, body: Data(body.prefix(contentLength)))
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        if _failNextRequests > 0 {
            _failNextRequests -= 1
            send(["error": "scripted failure"], status: 500, on: connection)
            return
        }
        guard request.headers["x-api-key"] == _apiKey else {
            send(["error": "Forbidden"], status: 403, on: connection)
            return
        }

        let parts = request.path.components(separatedBy: "?")
        let path = parts[0]
        let query = Self.parseQuery(parts.count > 1 ? parts[1] : "")

        switch (request.method, path) {
        case ("GET", "/rest/system/version"):
            send(["version": _versionTag, "arch": "arm64"], on: connection)
        case ("GET", "/rest/system/status"):
            send(["myID": _myID], on: connection)
        case ("GET", "/rest/config/options"):
            send(["releasesURL": "https://upgrades.syncthing.net/meta.json",
                  "upgradeToPreReleases": false], on: connection)
        case ("PATCH", "/rest/config/options"):
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let hours = json["autoUpgradeIntervalH"] as? Int {
                _recordedAutoUpgradeIntervals.append(hours)
            }
            send([:], on: connection)
        case ("GET", "/rest/config/devices"):
            send(_devices.map { ["deviceID": $0.deviceID, "paused": $0.paused] }, on: connection)
        case ("GET", "/rest/config/folders"):
            send(_folders.map { ["id": $0.id, "label": $0.label, "path": $0.path] }, on: connection)
        case ("GET", "/rest/db/status"):
            let state = _folders.first { $0.id == query["folder"] }?.state ?? "idle"
            send(["state": state], on: connection)
        case ("GET", "/rest/folder/errors"):
            let errors = _folders.first { $0.id == query["folder"] }?.errors ?? []
            send(["folder": query["folder"] ?? "", "page": 1, "perpage": 100,
                  "errors": errors.map { ["path": $0.path, "error": $0.error] }],
                 on: connection)
        case ("GET", "/rest/events"):
            handleEvents(query, on: connection)
        default:
            send(["error": "not found"], status: 404, on: connection)
        }
    }

    private func handleEvents(_ query: [String: String], on connection: NWConnection) {
        let since = query["since"].flatMap(Int.init) ?? 0
        let limit = query["limit"].flatMap(Int.init)
        let timeout = query["timeout"].flatMap(Double.init) ?? 50

        var matching = events.filter { $0.id > since }.map(\.json)
        if let limit { matching = Array(matching.suffix(limit)) }
        if !matching.isEmpty {
            send(matching, on: connection)
            return
        }

        // Long-poll: park until an event is pushed or the (capped) timeout lapses.
        let waiter = Waiter(since: since) { [weak self] events in
            self?.send(events, on: connection)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + min(timeout, 0.25))
        timer.setEventHandler { [weak self, weak waiter] in
            guard let self, let waiter else { return }
            self.waiters.removeAll { $0 === waiter }
            waiter.respond([])
        }
        waiter.timer = timer
        waiters.append(waiter)
        timer.resume()
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") where !pair.isEmpty {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            result[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return result
    }

    // MARK: - Response writing

    private func send(_ json: Any, status: Int = 200, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeAll { $0 === connection }
        })
    }
}
