import Foundation
import Darwin
import os

/// The managed daemon as the Syncthing update mechanism sees it: the lifecycle
/// operations an in-place binary upgrade sequences — stop, swap, start, and
/// confirm — so the mechanism never reaches into process internals.
/// `SyncthingProcess` is the production conformer; tests script one.
protocol ManagedDaemon: AnyObject {
    /// Whether the daemon is spawned and not known to have exited.
    var isRunning: Bool { get }
    /// Stop the daemon without latching the terminal guard. Returns the launch
    /// token of the stop, or nil when a terminal stop (quit) superseded it —
    /// the app is exiting.
    @MainActor func shutdown() async -> LaunchToken?
    /// Swap the binary via Syncthing's own upgrader. Requires the daemon to be
    /// stopped. Whatever happens, a runnable binary is left in place.
    @MainActor func upgradeBinary(from assetURL: URL) async throws -> BinarySwap
    /// Launch the daemon; resolves once it is spawned and throws a
    /// `DaemonLaunchError` if the launch failed before exec (provenance,
    /// config, spawn) or was superseded. `token` binds the launch to the stop
    /// that preceded it: if another stop landed since (a mode switch), the
    /// launch is refused with `.superseded` instead of spawning a daemon the
    /// app no longer expects.
    @MainActor func start(after token: LaunchToken?) async throws
}

extension ManagedDaemon {
    /// Launch unconditionally — the app's own launch paths, which are the
    /// current intent by definition.
    @MainActor func start() async throws { try await start(after: nil) }
}

/// The receipt of a `shutdown()`: names the launch generation that stop
/// minted, so a later `start(after:)` can tell whether it is still the stop's
/// intended successor. Opaque outside the process layer.
struct LaunchToken: Equatable {
    fileprivate let epoch: Int
}

/// Why a `ManagedDaemon.start()` didn't end in a spawned daemon. A `.failed`
/// launch is also reflected in the daemon's state (with the same message);
/// `.superseded` means a quit or a mode switch landed first and nothing was
/// spawned — not an error condition, just not a launch.
enum DaemonLaunchError: LocalizedError, Equatable {
    case superseded
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .superseded: "Syncthing launch superseded"
        case let .failed(message): message
        }
    }
}

/// Launches and supervises the managed Syncthing daemon as a child process.
///
/// Runs an *isolated* instance: its own home directory (config + database) under
/// our app-support directory. We **never write Syncthing's `config.xml`** — we let
/// Syncthing pick free GUI/listen ports (it does this itself), read the API key it
/// generated, and pin the GUI port via a CLI flag using a value persisted on *our*
/// side. The one option we enforce (`autoUpgradeIntervalH = 0`) is applied via the
/// REST API, not by editing the file.
///
/// Also the one place the binary's one-shot subcommands run (`generate` at first
/// launch, `upgrade` for updates) — `runCommand` — so every invocation of the
/// binary shares one spawn, relay, and timeout path.
final class SyncthingProcess: ManagedDaemon {
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
    /// `shutdown()`, `upgradeBinary(from:)`, and the launch path all check it,
    /// so a quit landing in the middle of an in-flight start or upgrade can't
    /// spawn an orphaned daemon. `shutdown()` stops the daemon via `beginStop()`
    /// (not `stop()`), so a non-terminal stop never sets this flag.
    private var isTerminating = false

    /// The in-flight `start()`'s continuation: resolved exactly once, at the
    /// spawn (success), at a launch failure, or when the launch was superseded
    /// (`isTerminating` / `launchEpoch`). Main-thread confined; at most one
    /// start is in flight — `start()` returns at once while `state` is
    /// `.starting`, so the slot is never overwritten.
    private var spawnContinuation: CheckedContinuation<Void, Error>?

    /// The in-flight non-terminal stop, so concurrent `shutdown()` callers
    /// share one ladder on the pid instead of racing two. Main-thread confined.
    private var stopTask: Task<LaunchToken?, Never>?

    /// The one-shot subcommand currently running (`generate`, `upgrade`), so a
    /// terminal `stop()` can end it — an orphaned `upgrade` finishing after the
    /// app quit would swap the binary under whatever launches next. Written on
    /// the queue that runs the command, read on main: lock-guarded together
    /// with `commandsRefused`, which `stop()` raises so no command can start
    /// in the gap between its check and the child's registration.
    private var commandProcess: Process?
    private var commandsRefused = false
    private let commandLock = NSLock()

    /// How long a terminal `stop()` lets an in-flight one-shot run finish on
    /// its own before terminating it: an `upgrade` that completes its swap is
    /// exactly what the user asked for, and it takes seconds. Injectable seam.
    var commandQuitGrace: TimeInterval = 5

    /// Upper bound on a one-shot `upgrade` run: it downloads the release (tens
    /// of MB at worst) and swaps two files. Past it the process is terminated
    /// and the swap repaired (`BinarySwap.recoverIfInterrupted`). Injectable
    /// seam for the process tests.
    var upgradeTimeout: TimeInterval = 300

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

    /// Ladder graces for the NON-terminal stop (`shutdown()` — the mode switch
    /// and the pre-upgrade stop). A ceiling, not a delay: a healthy stop
    /// returns in well under a second regardless, and the grace only decides
    /// when a SLOW stop is escalated — where every lower rung is worse than
    /// waiting (SIGTERM re-requests a shutdown already in progress; SIGKILL
    /// ends a worker mid-database-close, crash-safe but recovery work at the
    /// next start). Slow stops are real: a just-booted worker in its startup
    /// scans took 10s to honor the REST shutdown (live, 2026-09-16 — the
    /// auto-install-at-launch timing, since the launch check fires as soon as
    /// the session connects), and that scales with folders and database size.
    /// 3s+3s impatience is what SIGKILLed the monitor and orphaned the worker
    /// on the DB lock in the 2026-08-11 failed-update incident. Still bounded
    /// (a wedged worker is escalated after a minute; the menu reads Updating
    /// throughout), with `reapOrphanedWorkers` making the SIGKILL rung safe.
    /// Injectable seam.
    var shutdownGraces: (rest: TimeInterval, term: TimeInterval) = (60, 5)

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

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Launch the daemon. Resolves once the daemon is spawned (`.running`);
    /// throws `DaemonLaunchError.failed` when the launch died before exec (the
    /// state is `.failed` with the same message) and `.superseded` when a quit
    /// or a mode switch cancelled it — including a mode switch that landed
    /// between the caller's `shutdown()` and this call, detected through
    /// `token`. No-op (returns) if already running or already launching.
    @MainActor
    func start(after token: LaunchToken?) async throws {
        guard !isTerminating else { throw DaemonLaunchError.superseded }
        if let token, token.epoch != launchEpoch { throw DaemonLaunchError.superseded }
        guard pid == nil else {
            Log.process.log("start ignored — daemon already running (monitor pid \(self.pid ?? -1))")
            return
        }
        guard state != .starting else {
            Log.process.log("start ignored — a launch is already in progress")
            return
        }
        let epoch = launchEpoch
        state = .starting

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            spawnContinuation = continuation
            // Generate (first run) can block briefly, so do prep off-main; the actual
            // launch returns to main to keep process state consistent.
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                do {
                    let plan = try self.prepareLaunch()
                    DispatchQueue.main.async { self.launchServe(plan: plan, epoch: epoch) }
                } catch {
                    DispatchQueue.main.async {
                        guard !self.isTerminating, epoch == self.launchEpoch else {
                            self.resolveSpawn(.failure(DaemonLaunchError.superseded))
                            return
                        }
                        // Full error for the log; the state message stays user-readable.
                        Log.process.error("launch prep failed: \(String(describing: error), privacy: .public)")
                        self.fail("Setup failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// The one exit for a launch that died before exec: the state carries the
    /// message for the menu, the continuation carries it to the caller.
    private func fail(_ message: String) {
        state = .failed(message)
        resolveSpawn(.failure(DaemonLaunchError.failed(message)))
    }

    private func resolveSpawn(_ result: Result<Void, Error>) {
        spawnContinuation?.resume(with: result)
        spawnContinuation = nil
    }

    /// Stop the daemon and wait for it to exit. Graceful ladder: ask Syncthing to shut
    /// down via REST (the worker owns the API; its clean exit takes the monitor with it),
    /// then SIGTERM, then SIGKILL. Synchronous — safe to call from
    /// applicationWillTerminate, where we must block until the daemon is actually down.
    func stop() {
        isTerminating = true            // latch: never relaunch after a terminal stop (quit)
        stopCommand()
        guard let pid = self.pid else { return }
        let request = beginStop()
        escalateAndReap(pid, restGrace: escalationGrace, termGrace: escalationGrace, rest: request)
        finishStop()
    }

    /// Stop the daemon *without* latching the terminal guard — the daemon-mode
    /// switch (managed → self-managed, or clearing the way before a managed
    /// launch) and the stop before a binary upgrade: the app keeps running and
    /// may `start()` again later. Bumping `launchEpoch` cancels an in-flight
    /// `start()`'s pending spawn, so a mode switch landing mid-start can't leak
    /// a daemon. Resolves on main once the daemon is down (immediately when
    /// nothing is running) with the stop's `LaunchToken`; nil means a terminal
    /// `stop()` superseded us mid-reap and the app is exiting — never start
    /// after it. Concurrent callers share the one in-flight ladder, and the
    /// LAST caller's token is the live one: an earlier caller's
    /// `start(after:)` is refused, because the later stop is the newer intent.
    @MainActor
    @discardableResult
    func shutdown() async -> LaunchToken? {
        guard !isTerminating else { return nil }
        launchEpoch &+= 1
        let token = LaunchToken(epoch: launchEpoch)
        if let inFlight = stopTask {
            _ = await inFlight.value
            return isTerminating ? nil : token
        }
        guard let pid = self.pid else {
            if state != .stopped { state = .stopped }   // an in-flight start was superseded
            return token
        }
        let request = beginStop()
        let graces = shutdownGraces
        let task = Task<LaunchToken?, Never> { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    self.escalateAndReap(pid, restGrace: graces.rest, termGrace: graces.term, rest: request)
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
            self.stopTask = nil
            guard !self.isTerminating else { return nil }
            self.finishStop()
            return token
        }
        stopTask = task
        return await task.value
    }

    // MARK: - Binary upgrade (Syncthing's own upgrader, run while stopped)

    /// Why `upgradeBinary(from:)` didn't end in a swapped binary. In every case
    /// the binary on disk is runnable (the previous one, restored if needed).
    enum UpgradeError: LocalizedError, Equatable {
        case daemonRunning
        case superseded
        case timedOut(after: TimeInterval)
        case exited(code: Int32)
        case signaled(Int32)
        var errorDescription: String? {
            switch self {
            case .daemonRunning: "Syncthing must be stopped before its binary is upgraded"
            case .superseded: "Syncthing upgrade superseded by quit"
            case let .timedOut(after): "Syncthing's upgrade didn't finish within \(Int(after))s"
            case let .exited(code): "Syncthing's upgrade exited with code \(code)"
            case let .signaled(signal): "Syncthing's upgrade was ended by signal \(signal)"
            }
        }
    }

    /// Swap the binary via `syncthing upgrade --from <asset>` — the daemon's own
    /// upgrader (download, release-signature verification against Syncthing's
    /// embedded signing key, rename to `.old`, move the new binary in), run as
    /// a one-shot process while no daemon is alive. That is the whole point:
    /// the rename happens with no live process tree, so no TCC identity ever
    /// reads `syncthing.old` (the permission-prompt and stuck-FDA incidents of
    /// the in-process upgrade). `--from` pins the exact asset the availability
    /// check selected; the signature covers the archive name too, so the URL
    /// must end in the real asset name (the upgrade feed's do).
    ///
    /// Requires the daemon to be stopped. Contract: whatever happens — exit
    /// error, our timeout, a quit's SIGTERM between the two renames — a
    /// runnable binary is left in place, the previous one restored if the swap
    /// was interrupted. The next `start()` re-verifies provenance as always.
    @MainActor
    func upgradeBinary(from assetURL: URL) async throws -> BinarySwap {
        guard !isTerminating else { throw UpgradeError.superseded }
        guard pid == nil else { throw UpgradeError.daemonRunning }
        let swap = BinarySwap(binaryURL: binaryURL)
        let arguments = ["upgrade", "--home", homeURL.path, "--from", assetURL.absoluteString]
        let timeout = upgradeTimeout
        Log.process.log("upgrade: running syncthing upgrade --from \(assetURL.absoluteString, privacy: .public)")
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<CommandOutcome, Error>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.runCommand(arguments, timeout: timeout) }
                DispatchQueue.main.async { continuation.resume(returning: result) }
            }
        }
        if swap.recoverIfInterrupted() {
            Log.process.log("upgrade: restored the previous binary after an interrupted swap")
        }
        switch outcome {
        case .success(.exited(0)):
            Log.process.log("upgrade: binary swapped")
            return swap
        case let .success(.exited(code)):
            throw UpgradeError.exited(code: code)
        case let .success(.signaled(signal)):
            throw isTerminating ? UpgradeError.superseded : UpgradeError.signaled(signal)
        case .success(.timedOut):
            throw UpgradeError.timedOut(after: timeout)
        case let .failure(error):
            throw error
        }
    }

    // MARK: - One-shot subcommands

    private enum CommandOutcome: Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut

        /// Human-readable, in the same dialect as the exit watcher's
        /// `describe(_:)` ("code N" / "signal N").
        var summary: String {
            switch self {
            case let .exited(code): "code \(code)"
            case let .signaled(signal): "signal \(signal)"
            case .timedOut: "timed out"
            }
        }
    }

    /// Run one of the binary's one-shot subcommands to completion, relaying its
    /// output to the log. Blocking — call off-main. A run that outlives
    /// `timeout` is SIGTERMed, then SIGKILLed if it lingers; a terminal
    /// `stop()` SIGTERMs it the same way (`terminateCommand`).
    private func runCommand(_ arguments: [String], timeout: TimeInterval) throws -> CommandOutcome {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = arguments
        // Never let the daemon's STNOUPGRADE leak into an upgrade run; the
        // subcommands otherwise inherit our environment.
        proc.environment = ProcessInfo.processInfo.environment.filter { $0.key != "STNOUPGRADE" }
        let subcommand = arguments.first ?? "?"
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        Self.relay(pipe.fileHandleForReading, prefix: "[\(subcommand)] ")

        // Launch and register under the one lock, so a terminal `stop()` either
        // sees the child or has already refused it — never a child it missed.
        try commandLock.withLock {
            guard !commandsRefused else { throw CommandRefused() }
            try proc.run()
            commandProcess = proc
        }
        defer { commandLock.withLock { commandProcess = nil } }

        // The watchdog only ever acts on a process that is still running: a
        // run that exits normally right at the deadline is a normal exit, and
        // the weak capture keeps a cancelled item from retaining the process
        // (and its pipe) until the deadline passes.
        var timedOut = false
        let watchdog = DispatchWorkItem { [weak proc, commandLock] in
            guard let proc, proc.isRunning else { return }
            commandLock.withLock { timedOut = true }
            Log.process.error("\(subcommand, privacy: .public) didn't finish within \(Int(timeout))s — terminating it")
            Self.terminate(proc)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        switch proc.terminationReason {
        case .exit:
            return .exited(proc.terminationStatus)
        default:
            return commandLock.withLock({ timedOut }) ? .timedOut : .signaled(proc.terminationStatus)
        }
    }

    /// A one-shot run refused because a terminal `stop()` has begun.
    private struct CommandRefused: Error {}

    /// SIGTERM, wait, then SIGKILL if the process lingers; returns once it is
    /// gone. Blocking — the watchdog runs it off-main, the terminal `stop()`
    /// on the quitting main thread, where blocking is the point. Go exits on
    /// SIGTERM at once (no deferred cleanup — hence
    /// `BinarySwap.recoverIfInterrupted`), so the KILL is a backstop.
    private static func terminate(_ proc: Process) {
        guard proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        if waitForDeath(pid, 2) { return }
        kill(pid, SIGKILL)
        _ = waitForDeath(pid, 2)
    }

    /// The terminal stop's handling of an in-flight one-shot run: refuse any
    /// new one, let the current one finish on its own for `commandQuitGrace`
    /// (a completing `upgrade` is the requested outcome), then terminate it.
    /// Returns with the child gone either way, so the app never exits with a
    /// swap in an unknown state.
    private func stopCommand() {
        let running: Process? = commandLock.withLock {
            commandsRefused = true
            return commandProcess
        }
        guard let running, running.isRunning else { return }
        let name = running.arguments?.first ?? "?"
        if Self.waitForDeath(running.processIdentifier, commandQuitGrace) {
            Log.process.log("in-flight \(name, privacy: .public) run finished before quit")
            return
        }
        Log.process.log("terminating the in-flight \(name, privacy: .public) run")
        Self.terminate(running)
    }

    /// The fate of a REST shutdown request, shared with the ladder thread: the
    /// REST rung waits only while the request can still succeed.
    private final class RestShutdownRequest {
        private let lock = NSLock()
        private var failed = false
        var hasFailed: Bool { lock.withLock { failed } }
        func markFailed() { lock.withLock { failed = true } }
    }

    /// Stop watching for an unexpected exit (so the deliberate reap below isn't mistaken
    /// for a crash) and fire the graceful REST shutdown. Actual exit is detected by
    /// `escalateAndReap`; the returned request only tells it whether the REST rung is
    /// still worth waiting on (no endpoint, or a refused request, means it isn't).
    private func beginStop() -> RestShutdownRequest {
        exitSource?.cancel()
        exitSource = nil
        let request = RestShutdownRequest()
        if let urlString = guiURL, let url = URL(string: urlString), let key = apiKey {
            let api = SyncthingAPI(baseURL: url, apiKey: key)
            Task {
                do {
                    try await api.shutdown()
                    Log.process.log("REST shutdown request accepted")
                } catch {
                    Log.process.log("REST shutdown request failed: \(error.localizedDescription, privacy: .public)")
                    request.markFailed()
                }
            }
        } else {
            Log.process.log("no REST endpoint available — stopping via signal")
            request.markFailed()
        }
        return request
    }

    /// Block until the daemon exits, escalating REST → SIGTERM → SIGKILL. Logs which
    /// stage actually stopped it (and how long it took). The ladder acts on the
    /// MONITOR (the pid we spawned); afterwards `reapOrphanedWorkers` confirms the
    /// worker died too — the ladder is not done while any lock-holder survives.
    /// The REST rung waits its grace only while the request stands: a missing
    /// endpoint or a refused request falls through to SIGTERM at once.
    private func escalateAndReap(_ pid: pid_t, restGrace: TimeInterval, termGrace: TimeInterval,
                                 rest request: RestShutdownRequest) {
        // Snapshot the monitor's children BEFORE stopping: if the ladder ever
        // reaches SIGKILL, the monitor dies alone and the worker survives as an
        // orphan still holding the database lock — a respawn would crash-loop
        // on it (the 2026-08-11 failed-update incident).
        let workers = Self.childPIDs(of: pid)
        defer { reapOrphanedWorkers(workers) }

        let start = Date()
        func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }

        if waitForExit(pid, restGrace, abortIf: { request.hasFailed }) {
            Log.process.log("stopped via REST shutdown (\(elapsed(), privacy: .public))")
            return
        }
        if request.hasFailed {
            Log.process.log("REST shutdown unavailable — falling back to SIGTERM")
        } else {
            Log.process.log("REST shutdown didn't complete in \(restGrace)s — falling back to SIGTERM")
        }
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
            if Self.waitForDeath(worker, 3) { continue }
            Log.process.log("worker \(worker) survived the monitor — sending SIGKILL")
            kill(worker, SIGKILL)
            if !Self.waitForDeath(worker, 2) {
                Log.process.error("worker \(worker) did not exit after SIGKILL")
            }
        }
    }

    /// Poll until `pid` no longer exists (kill-0 probe; workers are
    /// grandchildren, so `waitpid` doesn't apply). PID reuse inside this
    /// seconds-scale window is not a realistic concern.
    private static func waitForDeath(_ pid: pid_t, _ seconds: TimeInterval) -> Bool {
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

    /// Poll `waitpid` until the process is reaped, `seconds` elapse, or
    /// `abortIf` says the wait is pointless; returns whether reaped.
    private func waitForExit(_ pid: pid_t, _ seconds: TimeInterval,
                             abortIf: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return true }                  // reaped
            if r == -1 && errno != EINTR { return true } // already gone / error
            if Date() >= deadline || abortIf() { return false }
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

    /// First launch: have Syncthing write its initial `config.xml` + keys.
    private func runGenerate() throws {
        let outcome = try runCommand(["generate", "--home", homeURL.path], timeout: 60)
        guard outcome == .exited(0) else {
            throw GenerateError(outcome: outcome.summary)
        }
    }

    private struct GenerateError: LocalizedError {
        let outcome: String
        var errorDescription: String? { "Syncthing couldn't create its initial configuration (\(outcome))" }
    }

    // MARK: - Launch

    private func launchServe(plan: LaunchPlan, epoch: Int) {
        // A terminal stop or a mode-switch shutdown may have landed while we
        // prepared off-main; never spawn after either, and never beside a
        // daemon that is already tracked.
        guard !isTerminating, epoch == launchEpoch, pid == nil else {
            resolveSpawn(.failure(DaemonLaunchError.superseded))
            return
        }
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
            fail("Couldn't create a pipe for Syncthing output")
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
        // via `upgradeBinary(from:)` while stopped, on explicit consent). The flag
        // 501s the daemon's GET /rest/system/upgrade, which is what empties the
        // Web UI's upgrade banner, and disables its auto-upgrade scheduler.
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
            fail("Couldn't launch Syncthing: \(String(cString: strerror(rc)))")
            return
        }

        // Log the daemon's output.
        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        Self.relay(handle)
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
        resolveSpawn(.success(()))
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

    /// Relay a child's combined stdout/stderr to the unified log until EOF —
    /// the daemon's and the one-shot subcommands' output alike (the latter
    /// prefixed with their name). Known nit, shared by design so it is fixed
    /// in one place: a multi-line chunk logs as one entry.
    private static func relay(_ handle: FileHandle, prefix: String = "") {
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }   // EOF
            if let text = String(data: data, encoding: .utf8) {
                Log.syncthing.log("\(prefix, privacy: .public)\(text.trimmingCharacters(in: .newlines), privacy: .public)")
            }
        }
    }

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
