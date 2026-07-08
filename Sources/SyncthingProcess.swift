import Foundation
import Darwin

/// Launches and supervises the managed Syncthing daemon as a child process.
///
/// Runs an *isolated* instance: its own home directory (config + database) under
/// our app-support directory. We **never write Syncthing's `config.xml`** — we let
/// Syncthing pick free GUI/listen ports (it does this itself), read the API key it
/// generated, and pin the GUI port via a CLI flag using a value persisted on *our*
/// side. The one option we enforce (`autoUpgradeIntervalH = 0`) is applied via the
/// REST API, not by editing the file.
final class SyncthingProcess {
    enum State: Equatable {
        case stopped
        case starting
        case running(guiURL: String)
        case failed(String)
    }

    /// Called on the main thread whenever `state` changes.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }

    /// The daemon's API key, read from `config.xml` once running. Used by the REST client.
    private(set) var apiKey: String?

    private let binaryURL: URL
    private let homeURL: URL
    private var pid: pid_t?
    private var stdoutHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var guiURL: String?     // the running worker's REST base, for graceful shutdown

    /// Latched `true` by `stop()` — the supervisor is terminating and must never
    /// (re)launch the daemon again. This is the single lifecycle guard: `start()`,
    /// `restart()`, and the launch path all check it, so a quit landing in the middle of
    /// an in-flight start/restart can't spawn an orphaned daemon. `restart()` stops the
    /// daemon via `beginStop()` (not `stop()`), so a restart never sets this flag.
    private var isTerminating = false

    /// Where we persist *our* chosen GUI port (not in Syncthing's config).
    private static let guiPortDefaultsKey = "syncthing.managedGUIPort"

    init(binaryURL: URL = ReleaseUpdater.installedBinaryURL,
         homeURL: URL = SyncthingProcess.defaultHomeURL) {
        self.binaryURL = binaryURL
        self.homeURL = homeURL
    }

    static var defaultHomeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Syncthing Menu/home", isDirectory: true)
    }

    /// Launch the daemon. No-op if already running.
    func start() {
        guard !isTerminating, pid == nil else { return }
        state = .starting

        // Generate (first run) can block briefly, so do prep off-main; the actual
        // launch returns to main to keep process state consistent.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let plan = try self.prepareLaunch()
                DispatchQueue.main.async { self.launchServe(plan: plan) }
            } catch {
                DispatchQueue.main.async {
                    guard !self.isTerminating else { return }
                    self.state = .failed("Setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stop the daemon and wait for it to exit. Graceful ladder: ask Syncthing to shut
    /// down via REST (the worker owns the API; its clean exit takes the monitor with it),
    /// then SIGTERM, then SIGKILL. Synchronous — safe to call from
    /// applicationWillTerminate, where we must block until the daemon is actually down.
    func stop() {
        isTerminating = true            // latch: never relaunch after a terminal stop (quit)
        guard let pid = self.pid else { return }
        beginStop()
        escalateAndReap(pid)
        finishStop()
    }

    /// Stop and relaunch without blocking the caller. Used after a self-upgrade so the
    /// monitor re-roots on the canonical `syncthing` (with a fresh disclaim) instead of
    /// staying backed by the renamed `syncthing.old`. Equivalent to a fresh launch.
    func restart() {
        guard !isTerminating else { return }
        guard let pid = self.pid else { start(); return }
        beginStop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.escalateAndReap(pid)
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }   // superseded by a quit
                self.finishStop()
                self.start()
            }
        }
    }

    /// Stop watching for an unexpected exit (so the deliberate reap below isn't mistaken
    /// for a crash) and fire the graceful REST shutdown (fire-and-forget — actual exit is
    /// detected by `escalateAndReap`, so the HTTP response is irrelevant).
    private func beginStop() {
        exitSource?.cancel()
        exitSource = nil
        if let urlString = guiURL, let url = URL(string: urlString), let key = apiKey {
            let api = SyncthingAPI(baseURL: url, apiKey: key)
            Task {
                do {
                    try await api.shutdown()
                    NSLog("[syncthing] REST shutdown request accepted")
                } catch {
                    NSLog("[syncthing] REST shutdown request failed: \(error.localizedDescription)")
                }
            }
        } else {
            NSLog("[syncthing] no REST endpoint available — stopping via signal")
        }
    }

    /// Block until the daemon exits, escalating REST → SIGTERM → SIGKILL. Logs which
    /// stage actually stopped it (and how long it took).
    private func escalateAndReap(_ pid: pid_t) {
        let start = Date()
        func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }

        if waitForExit(pid, 3) {
            NSLog("[syncthing] stopped via REST shutdown (\(elapsed()))")
            return
        }
        NSLog("[syncthing] REST shutdown didn't complete in 3s — falling back to SIGTERM")
        kill(pid, SIGTERM)
        if waitForExit(pid, 3) {
            NSLog("[syncthing] stopped via SIGTERM (\(elapsed()))")
            return
        }
        NSLog("[syncthing] SIGTERM didn't complete in 3s — sending SIGKILL")
        kill(pid, SIGKILL)
        _ = waitForExit(pid, 2)
        NSLog("[syncthing] stopped via SIGKILL (\(elapsed()))")
    }

    /// Poll `waitpid` until the process is reaped or `seconds` elapse; returns whether reaped.
    private func waitForExit(_ pid: pid_t, _ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return true }                  // reaped
            if r == -1 && errno != EINTR { return true } // already gone / error
            if Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    /// Clear process state after exit. Must run on the main thread (mutates `state`).
    private func finishStop() {
        pid = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        guiURL = nil
        state = .stopped
    }

    // MARK: - Launch planning (no config writes)

    private struct LaunchPlan {
        let apiKey: String?
        let guiURL: String
        /// When set, passed via `--gui-address` (used for the "dynamic" case).
        let guiAddressOverride: String?
    }

    private func prepareLaunch() throws -> LaunchPlan {
        let fm = FileManager.default
        try fm.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let configURL = homeURL.appendingPathComponent("config.xml")
        if !fm.fileExists(atPath: configURL.path) {
            try runGenerate()
        }

        let config = try SyncthingConfig(contentsOf: configURL)

        // Respect a concrete, user/Syncthing-set GUI address. Otherwise the config
        // says "dynamic", so we pin a stable port of our own (persisted on our side)
        // and pass it via --gui-address. Either way we never write Syncthing's config.
        if let concrete = config.concreteGUIURL {
            return LaunchPlan(apiKey: config.apiKey, guiURL: concrete, guiAddressOverride: nil)
        } else {
            let address = "127.0.0.1:\(persistedGUIPort())"
            return LaunchPlan(apiKey: config.apiKey,
                              guiURL: "http://\(address)",
                              guiAddressOverride: address)
        }
    }

    private func runGenerate() throws {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["generate", "--home", homeURL.path]
        try proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Launch

    private func launchServe(plan: LaunchPlan) {
        // A terminal stop may have landed while we prepared off-main; never spawn after that.
        guard !isTerminating else { return }
        var args = [binaryURL.path, "serve", "--home", homeURL.path, "--no-browser"]
        if let override = plan.guiAddressOverride {
            args += ["--gui-address", override]
        }

        // Pipe the daemon's stdout+stderr back for logging.
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            state = .failed("Couldn't create a pipe for Syncthing output")
            return
        }
        let readFD = fds[0], writeFD = fds[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, readFD)
        posix_spawn_file_actions_addclose(&fileActions, writeFD)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Disclaim TCC responsibility so the daemon is its OWN responsible process —
        // required for a Full Disk Access grant on the (out-of-bundle) Syncthing binary
        // to take effect. Without it the daemon inherits our app's TCC context, which —
        // being out-of-bundle — does not carry the grant. Verified in the FDA spike.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        if let disclaim = Self.disclaimFn {
            _ = disclaim(&attr, 1)
        } else {
            NSLog("[syncthing] warning: disclaim API unavailable; FDA grants on the daemon may not apply")
        }
        defer { posix_spawnattr_destroy(&attr) }

        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // STNOUPGRADE: the daemon must never advertise or perform upgrades on its
        // own — Syncthing Menu owns that flow (check via SyncthingReleases, install
        // via POST /rest/system/upgrade, then the re-root). The flag 501s the
        // daemon's GET /rest/system/upgrade, which is what empties the Web UI's
        // upgrade banner; the POST is unaffected (verified live on v2.1.1).
        var environment = ProcessInfo.processInfo.environment
        environment["STNOUPGRADE"] = "1"
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var newPid: pid_t = 0
        let rc = posix_spawn(&newPid, binaryURL.path, &fileActions, &attr, argv, envp)
        close(writeFD)   // the parent never writes

        guard rc == 0 else {
            close(readFD)
            state = .failed("Couldn't launch Syncthing: \(String(cString: strerror(rc)))")
            return
        }

        // Log the daemon's output.
        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }   // EOF
            if let text = String(data: data, encoding: .utf8) {
                NSLog("[syncthing] \(text.trimmingCharacters(in: .newlines))")
            }
        }
        stdoutHandle = handle

        // Detect unexpected exits. An intentional stop() cancels this and reaps itself.
        let source = DispatchSource.makeProcessSource(identifier: newPid, eventMask: .exit,
                                                      queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.exitSource?.cancel()
            self.exitSource = nil
            var status: Int32 = 0
            waitpid(newPid, &status, WNOHANG)
            self.pid = nil
            self.stdoutHandle?.readabilityHandler = nil
            self.stdoutHandle = nil
            if !self.isTerminating {
                // TODO: restart with backoff on unexpected exit.
                self.state = .failed("Syncthing exited (\(Self.describe(status)))")
            }
        }
        source.resume()
        exitSource = source
        pid = newPid

        apiKey = plan.apiKey
        guiURL = plan.guiURL
        state = .running(guiURL: plan.guiURL)
        NSLog("Syncthing daemon started at \(plan.guiURL) (home: \(homeURL.path))")
    }

    // MARK: - Disclaimed spawn (TCC responsible process)

    private typealias DisclaimFn =
        @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// `responsibility_spawnattrs_setdisclaim` (private libsystem API) makes a spawned
    /// child its OWN TCC responsible process — so a Full Disk Access grant on the
    /// out-of-bundle Syncthing binary actually applies. Resolved at runtime via dlsym;
    /// nil if unavailable (then we spawn without it).
    private static let disclaimFn: DisclaimFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2)!,   // RTLD_DEFAULT
                              "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: DisclaimFn.self)
    }()

    /// Human-readable description of a `waitpid` status.
    private static func describe(_ status: Int32) -> String {
        (status & 0x7f) == 0 ? "code \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
    }

    // MARK: - GUI port persistence (our side, never Syncthing's config)

    private func persistedGUIPort() -> UInt16 {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: Self.guiPortDefaultsKey)
        if stored > 0, let port = UInt16(exactly: stored), Self.isPortFree(port) {
            return port
        }
        let port = Self.findFreePort() ?? 8384
        defaults.set(Int(port), forKey: Self.guiPortDefaultsKey)
        return port
    }

    // MARK: - Port helpers

    private static func isPortFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func findFreePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0   // let the OS assign a free port
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        if named != 0 { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }
}
