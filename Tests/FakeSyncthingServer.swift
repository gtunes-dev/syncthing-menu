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
        var name = ""
        /// Served by /rest/system/connections (the monitor's connectedness seed).
        var connected = false
    }

    struct Folder {
        var id: String
        var label = ""
        var path = "/tmp"
        var state = "idle"
        /// Paused folders are not running: /rest/folder/errors returns 404
        /// "folder is paused" for them (mirrors the real daemon, verified
        /// live 2026-08-03).
        var paused = false
        /// Folder type as the config reports it ("sendreceive" / "sendonly"
        /// / "receiveonly") — drives the feed's delivery expectation.
        var type = "sendreceive"
        /// Device ids the folder is shared with, ourselves included. nil =
        /// shared with every configured device (the common test setup).
        var sharedWith: [String]? = nil
        /// Current scan/pull errors, served by /rest/folder/errors.
        var errors: [(path: String, error: String)] = []
        /// The folder-level error text /rest/db/status reports (a stopped
        /// folder); nil = healthy.
        var error: String? = nil
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

    /// Every request path (with query) the server received, in order — lets
    /// tests assert what traffic DID and DIDN'T happen (e.g. the activity
    /// feed's polls-only-while-visible contract).
    private var _requestedPaths: [String] = []

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

    /// Park every request whose path contains `substring` — the connection
    /// stays open, no response — until `releaseHeldRequests()`. Lets a test
    /// freeze a consumer mid-batch on a network await and act on it
    /// meanwhile (the activity feed's commit-epoch contract).
    private var _holdSubstring: String?
    private var _heldRequests: [(Request, NWConnection)] = []

    func holdRequests(containing substring: String) {
        queue.sync { _holdSubstring = substring }
    }

    var heldRequestCount: Int {
        queue.sync { _heldRequests.count }
    }

    /// Stop holding and answer every parked request normally.
    func releaseHeldRequests() {
        queue.sync {
            _holdSubstring = nil
            let held = _heldRequests
            _heldRequests = []
            for (request, connection) in held { dispatch(request, on: connection) }
        }
    }

    /// Every `autoUpgradeIntervalH` value PATCHed to /rest/config/options, in
    /// order — lets tests assert the no-self-upgrade invariant was (re)applied.
    var recordedAutoUpgradeIntervals: [Int] {
        queue.sync { _recordedAutoUpgradeIntervals }
    }

    var requestedPaths: [String] {
        queue.sync { _requestedPaths }
    }

    /// Scripted /rest/db/remoteneed responses, keyed by "folder|device".
    /// Unscripted pairs get a 404 — the "query failed, rows stay awaiting"
    /// degradation path.
    private var _remoteNeeds: [String: (names: [String], perpage: Int)] = [:]

    /// Scripted /rest/db/file authorship, keyed by "folder|path". Unscripted
    /// paths get a 404 — the "lookup failed, origin stays —" degradation path.
    private var _fileAuthors: [String: String] = [:]

    /// Scripted /rest/db/completion, keyed by "folder|device". Unscripted
    /// pairs get a 404 — how the real daemon answers for a device that
    /// doesn't share the folder.
    private var _completions: [String: (needItems: Int, needDeletes: Int)] = [:]

    /// Script one device's position for one folder (needItems + needDeletes;
    /// completion % derived: 100 when both are zero, else 50).
    func setCompletion(folder: String, device: String, needItems: Int, needDeletes: Int = 0) {
        queue.sync { _completions["\(folder)|\(device)"] = (needItems, needDeletes) }
    }

    /// Script the `modifiedBy` (short device id) one db/file query returns.
    func setFileAuthor(folder: String, path: String, modifiedBy: String) {
        queue.sync { _fileAuthors["\(folder)|\(path)"] = modifiedBy }
    }

    /// Scripted /rest/db/file availability (full device ids), keyed by
    /// "folder|path".
    private var _fileAvailability: [String: [String]] = [:]

    /// Script which devices already have the file (db/file `availability`).
    func setFileAvailability(folder: String, path: String, devices: [String]) {
        queue.sync { _fileAvailability["\(folder)|\(path)"] = devices }
    }

    /// Script the need list one remoteneed query returns. `perpage` echoes in
    /// the response; setting it to `names.count` models a truncated (full)
    /// page, whose absences must not be trusted.
    func setRemoteNeed(folder: String, device: String, names: [String],
                       perpage: Int = 1000) {
        queue.sync { _remoteNeeds["\(folder)|\(device)"] = (names, perpage) }
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
        pushEvents([(type: type, data: data)])
    }

    /// Append several events ATOMICALLY: parked long-polls release once, with
    /// the whole batch — how a real daemon delivers events that accumulated
    /// between polls. Lets tests exercise same-batch behavior (e.g. the
    /// feed's ItemStarted+ItemFinished collapse) deterministically.
    func pushEvents(_ batch: [(type: String, data: [String: Any])]) {
        queue.sync {
            for item in batch {
                let id = nextEventID
                nextEventID += 1
                events.append((id: id, json: [
                    "id": id, "globalID": id, "type": item.type,
                    "time": "2026-01-01T00:00:00Z", "data": item.data,
                ]))
            }
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
        _requestedPaths.append(request.path)
        if let hold = _holdSubstring, request.path.contains(hold) {
            _heldRequests.append((request, connection))
            return
        }
        dispatch(request, on: connection)
    }

    private func dispatch(_ request: Request, on connection: NWConnection) {
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
            send(_devices.map { ["deviceID": $0.deviceID, "paused": $0.paused, "name": $0.name] },
                 on: connection)
        case ("GET", "/rest/system/connections"):
            send(["connections": Dictionary(uniqueKeysWithValues: _devices.map {
                ($0.deviceID, ["connected": $0.connected])
            })], on: connection)
        case ("GET", "/rest/config/folders"):
            send(_folders.map { folder in
                ["id": folder.id, "label": folder.label, "path": folder.path,
                 "paused": folder.paused, "type": folder.type,
                 "devices": (folder.sharedWith ?? _devices.map(\.deviceID))
                     .map { ["deviceID": $0] }] as [String: Any]
            }, on: connection)
        case ("GET", "/rest/db/status"):
            let folder = _folders.first { $0.id == query["folder"] }
            send(["state": folder?.state ?? "idle", "error": folder?.error ?? ""],
                 on: connection)
        case ("GET", "/rest/folder/errors"):
            guard let folder = _folders.first(where: { $0.id == query["folder"] }),
                  !folder.paused else {
                // The real daemon 404s ("folder is paused") — the folder
                // isn't running, so it has no error store to read.
                send(["error": "folder is paused"], status: 404, on: connection)
                return
            }
            send(["folder": folder.id, "page": 1, "perpage": 100,
                  "errors": folder.errors.map { ["path": $0.path, "error": $0.error] }],
                 on: connection)
        case ("GET", "/rest/db/completion"):
            guard let folder = query["folder"], let device = query["device"],
                  let entry = _completions["\(folder)|\(device)"] else {
                send(["error": "no such object"], status: 404, on: connection)
                return
            }
            send(["completion": entry.needItems + entry.needDeletes == 0 ? 100.0 : 50.0,
                  "needItems": entry.needItems, "needDeletes": entry.needDeletes],
                 on: connection)
        case ("GET", "/rest/db/file"):
            guard let folder = query["folder"], let file = query["file"] else {
                send(["error": "no such object"], status: 404, on: connection)
                return
            }
            let author = _fileAuthors["\(folder)|\(file)"]
            let availability = _fileAvailability["\(folder)|\(file)"]
            guard author != nil || availability != nil else {
                send(["error": "no such object"], status: 404, on: connection)
                return
            }
            var payload: [String: Any] = [
                "availability": (availability ?? []).map { ["id": $0, "fromTemporary": false] }
            ]
            if let author { payload["global"] = ["modifiedBy": author] }
            send(payload, on: connection)
        case ("GET", "/rest/db/remoteneed"):
            guard let folder = query["folder"], let device = query["device"],
                  let entry = _remoteNeeds["\(folder)|\(device)"] else {
                send(["error": "not found"], status: 404, on: connection)
                return
            }
            send(["files": entry.names.map { ["name": $0] },
                  "page": 1, "perpage": entry.perpage], on: connection)
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
