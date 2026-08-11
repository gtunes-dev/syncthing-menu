import Foundation
import Darwin
import os

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
        didSet {
            // The transition trail is the postmortem for spawn failures: a launch
            // that dies before exec never reaches the daemon's own log file.
            switch state {
            case .stopped:
                Log.process.log("state: stopped")
            case .starting:
                Log.process.log("state: starting")
            case let .running(guiURL):
                Log.process.log("state: running (\(guiURL, privacy: .public))")
            case let .failed(message):
                Log.process.error("state: failed — \(message, privacy: .public)")
            }
            onStateChange?(state)
        }
    }

    /// The daemon's API key, read from `config.xml` once running. Used by the REST client.
    private(set) var apiKey: String?

    private let binaryURL: URL
    private let homeURL: URL
    private var pid: pid_t?
    private var stdoutHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var guiURL: String?     // the running worker's REST base, for graceful shutdown
    /// Whether this run pinned the GUI address via `--gui-address` (the dynamic-config
    /// case). The CLI override outlives any config edit, so the address cannot drift
    /// mid-run; only the API key can. See `refreshEndpoint()`.
    private var usedGUIAddressOverride = false

    /// Latched `true` by `stop()` — the supervisor is terminating and must never
    /// (re)launch the daemon again. This is the single lifecycle guard: `start()`,
    /// `restart()`, `shutdown()`, and the launch path all check it, so a quit
    /// landing in the middle of an in-flight start/restart can't spawn an
    /// orphaned daemon. `restart()` stops the daemon via `beginStop()` (not
    /// `stop()`), so a restart never sets this flag.
    private var isTerminating = false

    /// Non-terminal supersession, complementing `isTerminating`: bumped by
    /// `shutdown()` (the daemon-mode switch), it invalidates an in-flight
    /// `start()`'s pending spawn without latching the terminal guard — the app
    /// keeps running and may `start()` again later. Main-thread confined.
    private var launchEpoch = 0

    /// Where we persist *our* chosen GUI port (not in Syncthing's config).
    private static let guiPortDefaultsKey = "syncthing.managedGUIPort"

    /// How long each rung of the stop ladder (REST → SIGTERM → SIGKILL) waits
    /// before escalating on the TERMINAL stop (`stop()`, which blocks the
    /// quitting main thread). Injectable seam: the process tests run the ladder
    /// without real multi-second waits.
    var escalationGrace: TimeInterval = 3

    /// Ladder graces for the NON-terminal stops (`restart()` — the post-upgrade
    /// re-root — and `shutdown()`, the mode switch). More patient than the quit
    /// ladder: the reap runs off-main, and a just-booted worker legitimately
    /// needs >6s to close its database — 3s+3s impatience is what SIGKILLed the
    /// monitor and orphaned the worker on the DB lock in the 2026-08-11
    /// failed-update incident. Not unbounded either: after an upgrade this
    /// stop is also what ends the swap's TCC exposure (see `restart()`), so the
    /// worst case stays tens of seconds, with `reapOrphanedWorkers` making the
    /// SIGKILL rung safe. Injectable seam.
    var shutdownGraces: (rest: TimeInterval, term: TimeInterval) = (15, 5)

    /// Verifies the binary's provenance before EVERY spawn (~35ms, off-main in
    /// launch prep) — fresh launch and Start Syncthing both pass through here,
    /// so a binary the daemon's self-upgrade wrote is checked at the next spawn.
    /// Injectable seam: the process tests spawn unsigned stub scripts.
    var verifyBinary: (URL) throws -> Void = BinaryVerifier.verifySyncthingBinary

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
        guard !isTerminating else { return }
        guard pid == nil else {
            Log.process.log("start ignored — daemon already running (monitor pid \(self.pid ?? -1))")
            return
        }
        let epoch = launchEpoch
        state = .starting

        // Generate (first run) can block briefly, so do prep off-main; the actual
        // launch returns to main to keep process state consistent.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let plan = try self.prepareLaunch()
                DispatchQueue.main.async { self.launchServe(plan: plan, epoch: epoch) }
            } catch {
                DispatchQueue.main.async {
                    guard !self.isTerminating, epoch == self.launchEpoch else { return }
                    // Full error for the log; the state message stays user-readable.
                    Log.process.error("launch prep failed: \(String(describing: error), privacy: .public)")
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
        escalateAndReap(pid, restGrace: escalationGrace, termGrace: escalationGrace)
        finishStop()
    }

    /// Stop and relaunch without blocking the caller — the post-upgrade re-root.
    /// The daemon has already swapped its binary and restarted itself, but the
    /// surviving monitor PID carries the swap's TCC baggage: during the rename
    /// dance its executable path read `syncthing.old`, and tccd's evaluation of
    /// that identity can stick to the PID (the 2026-08-11 FDA incident — folder
    /// permissions broken until relaunch). A fresh spawn — new PID, fresh
    /// disclaim, canonical path — is the only thing that definitively ends it.
    /// Runs the patient `shutdownGraces` ladder plus worker reaping: the
    /// just-booted worker stops gracefully, and nothing can survive holding the
    /// database lock when the fresh daemon spawns.
    func restart() {
        guard !isTerminating else { return }
        guard let pid = self.pid else {
            Log.process.log("restart with no daemon tracked — starting fresh")
            start()
            return
        }
        Log.process.log("restart: stopping monitor pid \(pid)")
        let epoch = launchEpoch
        beginStop()
        let graces = shutdownGraces
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.escalateAndReap(pid, restGrace: graces.rest, termGrace: graces.term)
            DispatchQueue.main.async {
                guard let self, !self.isTerminating,
                      epoch == self.launchEpoch else { return }   // superseded by a quit/mode switch
                self.finishStop()
                self.start()
            }
        }
    }

    /// Stop the daemon *without* latching the terminal guard — the daemon-mode
    /// switch (managed → self-managed, or clearing the way before a managed
    /// launch): the app keeps running and may `start()` again later. Bumping
    /// `launchEpoch` cancels an in-flight `start()`'s pending spawn, so a mode
    /// switch landing mid-start can't leak a daemon. `completion` runs on main
    /// once the daemon is down (immediately when nothing is running) — never
    /// after a terminal `stop()` superseded us, because then the app is exiting.
    func shutdown(completion: (() -> Void)? = nil) {
        guard !isTerminating else { return }
        launchEpoch &+= 1
        guard let pid = self.pid else {
            if state != .stopped { state = .stopped }   // an in-flight start was superseded
            completion?()
            return
        }
        beginStop()
        let graces = shutdownGraces
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.escalateAndReap(pid, restGrace: graces.rest, termGrace: graces.term)
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.finishStop()
                completion?()
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
                    Log.process.log("REST shutdown request accepted")
                } catch {
                    Log.process.log("REST shutdown request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            Log.process.log("no REST endpoint available — stopping via signal")
        }
    }

    /// Block until the daemon exits, escalating REST → SIGTERM → SIGKILL. Logs which
    /// stage actually stopped it (and how long it took). The ladder acts on the
    /// MONITOR (the pid we spawned); afterwards `reapOrphanedWorkers` confirms the
    /// worker died too — the ladder is not done while any lock-holder survives.
    private func escalateAndReap(_ pid: pid_t, restGrace: TimeInterval, termGrace: TimeInterval) {
        // Snapshot the monitor's children BEFORE stopping: if the ladder ever
        // reaches SIGKILL, the monitor dies alone and the worker survives as an
        // orphan still holding the database lock — a respawn would crash-loop
        // on it (the 2026-08-11 failed-update incident).
        let workers = Self.childPIDs(of: pid)
        defer { reapOrphanedWorkers(workers) }

        let start = Date()
        func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }

        if waitForExit(pid, restGrace) {
            Log.process.log("stopped via REST shutdown (\(elapsed(), privacy: .public))")
            return
        }
        Log.process.log("REST shutdown didn't complete in \(restGrace)s — falling back to SIGTERM")
        kill(pid, SIGTERM)
        if waitForExit(pid, termGrace) {
            Log.process.log("stopped via SIGTERM (\(elapsed(), privacy: .public))")
            return
        }
        Log.process.log("SIGTERM didn't complete in \(termGrace)s — sending SIGKILL")
        kill(pid, SIGKILL)
        _ = waitForExit(pid, 2)
        Log.process.log("stopped via SIGKILL (\(elapsed(), privacy: .public))")
    }

    /// Wait briefly for the monitor's children to exit (in a graceful stop they
    /// die before the monitor does, so this is normally an instant no-op), then
    /// SIGKILL any survivor: after the ladder nothing supervises them, and a
    /// surviving worker holds the daemon's database lock.
    private func reapOrphanedWorkers(_ workers: [pid_t]) {
        for worker in workers {
            if waitForDeath(worker, 3) { continue }
            Log.process.log("worker \(worker) survived the monitor — sending SIGKILL")
            kill(worker, SIGKILL)
            if !waitForDeath(worker, 2) {
                Log.process.error("worker \(worker) did not exit after SIGKILL")
            }
        }
    }

    /// Poll until `pid` no longer exists (kill-0 probe; workers are
    /// grandchildren, so `waitpid` doesn't apply). PID reuse inside this
    /// seconds-scale window is not a realistic concern.
    private func waitForDeath(_ pid: pid_t, _ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while kill(pid, 0) == 0 {
            if Date() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }

    /// The live child PIDs of `pid`, via libproc. Empty on any failure — the
    /// ladder then degrades to its old monitor-only behavior.
    private static let procPPIDOnly: UInt32 = 6   // PROC_PPID_ONLY (proc_info.h)
    static func childPIDs(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = pids.withUnsafeMutableBufferPointer {
            proc_listpids(procPPIDOnly, UInt32(pid),
                          $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
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
        try verifyBinary(binaryURL)

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

    // MARK: - Live endpoint (the session's discovery source)

    struct Endpoint: Equatable {
        let guiURL: String
        let apiKey: String?
    }

    /// Re-read the running daemon's REST endpoint from `config.xml`, for the
    /// session's connect/reconnect. The asymmetry is deliberate:
    ///
    /// - The **API key** always comes fresh from the file — a Web-UI key rotation
    ///   lands there immediately and applies to the live listener.
    /// - The **address** is fixed for this run when we pinned it via
    ///   `--gui-address` (the CLI override outlives any config edit), and re-read
    ///   otherwise — in the concrete-config case a Web-UI address change actually
    ///   moves the live listener.
    ///
    /// Also refreshes the values the graceful-stop ladder uses, so a REST shutdown
    /// after a key rotation doesn't knock with the stale key. Returns nil when the
    /// daemon isn't running.
    func refreshEndpoint() throws -> Endpoint? {
        guard let launchedURL = guiURL else { return nil }
        let configURL = homeURL.appendingPathComponent("config.xml")
        let config = try SyncthingConfig(contentsOf: configURL)
        let address = usedGUIAddressOverride ? launchedURL
                                             : (config.concreteGUIURL ?? launchedURL)
        apiKey = config.apiKey
        guiURL = address
        return Endpoint(guiURL: address, apiKey: config.apiKey)
    }

    private func runGenerate() throws {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["generate", "--home", homeURL.path]
        try proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Launch

    private func launchServe(plan: LaunchPlan, epoch: Int) {
        // A terminal stop or a mode-switch shutdown may have landed while we
        // prepared off-main; never spawn after either.
        guard !isTerminating, epoch == launchEpoch else { return }
        var args = [binaryURL.path, "serve", "--home", homeURL.path, "--no-browser"]
        // Durable daemon log, rotated by Syncthing itself (2 MiB × 3 old files).
        // The daemon TEES to this file — stdout still carries everything
        // (verified on v2.1.2), so the live relay to the unified log below is
        // unaffected. This file is what survives app quits and unified-log
        // retention: the artifact a user attaches to a bug report.
        args += ["--log-file", homeURL.appendingPathComponent("syncthing.log").path,
                 "--log-max-size", "2097152", "--log-max-old-files", "3"]
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
            Log.process.warning("disclaim API unavailable; FDA grants on the daemon may not apply")
        }
        defer { posix_spawnattr_destroy(&attr) }

        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // STNOUPGRADE: the daemon must never advertise or perform upgrades on its
        // own — Syncthing Menu owns that flow (check via SyncthingReleases, install
        // via POST /rest/system/upgrade on explicit consent). The flag 501s the
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
                Log.syncthing.log("\(text.trimmingCharacters(in: .newlines), privacy: .public)")
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
                // Surface the exit; deliberately no auto-restart (worker crashes
                // are already restarted by Syncthing's own monitor process).
                self.state = .failed("Syncthing exited (\(Self.describe(status)))")
            }
        }
        source.resume()
        exitSource = source
        pid = newPid

        apiKey = plan.apiKey
        guiURL = plan.guiURL
        usedGUIAddressOverride = plan.guiAddressOverride != nil
        state = .running(guiURL: plan.guiURL)
        Log.process.log("daemon started at \(plan.guiURL, privacy: .public) (monitor pid \(newPid), home: \(self.homeURL.path, privacy: .public))")
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
