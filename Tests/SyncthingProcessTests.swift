import Foundation
import Testing
@testable import SyncthingMenu

/// A scripted stand-in for the syncthing binary plus an isolated home directory.
/// The process layer spawns it exactly like the real daemon (posix_spawn, pipes,
/// exit watcher) and runs its one-shot subcommands exactly like the real ones
/// (`Process`, output relay, timeout), so these are integration tests of real
/// process mechanics — only the *behavior* of the child is scripted per test.
@MainActor
private final class StubDaemonFixture {
    let dir: URL
    let runsFile: URL
    let binary: URL
    let process: SyncthingProcess
    private(set) var states: [SyncthingProcess.State] = []

    /// `RUNS` in the script is replaced with a fixture-local path.
    init(script: String) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncthingProcessTests-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // A concrete GUI address (nothing listens on it): no --gui-address
        // pinning, and the stop ladder's REST rung fails instantly.
        try """
        <configuration version="37">
            <gui enabled="true" tls="false">
                <address>127.0.0.1:1</address>
                <apikey>stub-key</apikey>
            </gui>
        </configuration>
        """.write(to: home.appendingPathComponent("config.xml"),
                  atomically: true, encoding: .utf8)

        runsFile = dir.appendingPathComponent("runs")
        binary = dir.appendingPathComponent("syncthing")
        try Self.install(script: script, at: binary, runsFile: runsFile)

        process = SyncthingProcess(binaryURL: binary, homeURL: home)
        process.escalationGrace = 0.2
        process.shutdownGraces = (rest: 0.2, term: 0.2)
        process.verifyBinary = { _ in }   // the stubs are unsigned scripts
        process.onStateChange = { [weak self] in self?.states.append($0) }
    }

    static func install(script: String, at url: URL, runsFile: URL) throws {
        try script.replacingOccurrences(of: "RUNS", with: runsFile.path)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    var isRunning: Bool { process.isRunning }
    var isFailed: Bool { if case .failed = process.state { return true } else { return false } }
    var sawFailed: Bool { states.contains { if case .failed = $0 { return true } else { return false } } }

    /// What the stub was spawned as, in order (scripts append one line per run).
    var runs: [String] {
        ((try? String(contentsOf: runsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
    var runCount: Int { runs.count }

    func tearDown() {
        process.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
struct SyncthingProcessTests {

    private static let crashOnce = """
    #!/bin/sh
    echo run >> RUNS
    echo "stub: boom" >&2
    exit 7
    """

    private static let stayAlive = """
    #!/bin/sh
    echo run >> RUNS
    exec sleep 1000
    """

    private static let ignoreSIGTERM = """
    #!/bin/sh
    echo run >> RUNS
    trap '' TERM
    while :; do sleep 0.2; done
    """

    /// A "monitor" that forks a TERM-immune "worker" (pid written beside RUNS),
    /// then itself ignores TERM — forcing the ladder to SIGKILL the monitor and
    /// sweep the orphaned child.
    private static let forkingIgnoreSIGTERM = """
    #!/bin/sh
    echo run >> RUNS
    trap '' TERM
    sh -c 'trap "" TERM; echo $$ > RUNS.worker; while :; do sleep 0.2; done' &
    while :; do sleep 0.2; done
    """

    /// A stub that dispatches on its subcommand like the real binary: `serve`
    /// stays alive; `upgrade` runs `UPGRADE` (the swap behavior under test) —
    /// the real upgrader's rename-then-replace, an error exit, or a hang.
    private static func upgradable(upgrade: String) -> String {
        """
        #!/bin/sh
        case "$1" in
          upgrade)
            echo upgrade >> RUNS
            \(upgrade)
            ;;
          *)
            echo run >> RUNS
            exec sleep 1000
            ;;
        esac
        """
    }

    /// What Syncthing's upgrader does on disk: the running binary becomes
    /// `.old`, a new one takes its place (this one announces itself as
    /// `run-new` when served).
    private static let swapInPlace = """
    mv "$0" "$0.old"
    cat > "$0" <<'EOF'
    #!/bin/sh
    echo run-new >> RUNS
    exec sleep 1000
    EOF
    chmod 755 "$0"
    exit 0
    """

    // MARK: - Launch and exit

    /// `start()` resolves at the spawn; an unexpected exit afterwards surfaces
    /// as `.failed` with the exit reason, and deliberately does not respawn —
    /// detection without remediation is the decided behavior (worker crashes
    /// are Syncthing's own monitor's job).
    @Test func unexpectedExitFailsWithoutRespawning() async throws {
        let fixture = try StubDaemonFixture(script: Self.crashOnce)
        defer { fixture.tearDown() }

        try await fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.isFailed }
        guard case let .failed(message) = fixture.process.state else { return }
        #expect(message.contains("code 7"))

        // No supervision kicks in: one spawn, ever.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(fixture.runCount == 1)
        #expect(fixture.isFailed)
    }

    /// The default spawn path verifies provenance: with the real verifier in
    /// place (the fixture normally stubs it out), an unsigned binary is never
    /// spawned — `start()` throws the launch failure and the state carries it.
    @Test func unsignedBinaryIsNeverSpawned() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }
        fixture.process.verifyBinary = { try BinaryVerifier.verifySyncthingBinary(at: $0) }

        var thrown: DaemonLaunchError?
        do { try await fixture.process.start() } catch let error as DaemonLaunchError { thrown = error }
        guard case let .failed(message) = thrown else {
            Issue.record("expected a launch failure, got \(String(describing: thrown))")
            return
        }
        #expect(message.contains("verification"))
        #expect(fixture.runCount == 0)
        #expect(fixture.isFailed)
    }

    // MARK: - Stopping

    /// The stop ladder reaps the WHOLE process tree: if the monitor has to be
    /// SIGKILLed, its child (the "worker") must not survive as an orphan — a
    /// surviving worker holds the daemon's database lock and would crash-loop
    /// any respawn (the 2026-08-11 production failure). The stub ignores
    /// SIGTERM and forks a child that also ignores it, so the ladder must reach
    /// SIGKILL and then sweep the child.
    @Test func stopLadderReapsOrphanedWorker() async throws {
        let fixture = try StubDaemonFixture(script: Self.forkingIgnoreSIGTERM)
        defer { fixture.tearDown() }

        try await fixture.process.start()
        let workerPidFile = fixture.runsFile.path + ".worker"
        try await expectEventually(timeout: 15) {
            FileManager.default.fileExists(atPath: workerPidFile)
        }
        let text = try String(contentsOfFile: workerPidFile, encoding: .utf8)
        let worker = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))!

        #expect(await fixture.process.shutdown() != nil)
        #expect(kill(worker, 0) == -1)   // the orphan was reaped, not leaked
        #expect(fixture.process.state == .stopped)
    }

    /// `shutdown()` is a non-terminal stop: the daemon goes down cleanly —
    /// never through `.failed` — and, unlike `stop()`, the process can
    /// `start()` again afterwards (the mode switch back to managed; the
    /// restart after a binary upgrade).
    @Test func shutdownStopsNonTerminallyAndAllowsRestart() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }

        try await fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.runCount == 1 }

        #expect(await fixture.process.shutdown() != nil)
        #expect(fixture.process.state == .stopped)
        #expect(!fixture.sawFailed)

        try await fixture.process.start()
        #expect(fixture.isRunning)
        try await expectEventually(timeout: 15) { fixture.runCount == 2 }
    }

    /// A shutdown landing while a `start()` is still preparing off-main must
    /// cancel the pending spawn (the launch-epoch guard) — a mode switch can
    /// never leak a managed daemon — and the superseded `start()` says so.
    @Test func shutdownDuringStartCancelsPendingSpawn() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }
        // Hold the off-main launch prep at the verification step until released.
        let gate = DispatchSemaphore(value: 0)
        fixture.process.verifyBinary = { _ in gate.wait() }

        let launch = Task { try await fixture.process.start() }
        try await expectEventually { fixture.process.state == .starting }

        #expect(await fixture.process.shutdown() != nil)
        #expect(fixture.process.state == .stopped)

        gate.signal()   // prep resumes — its spawn must be refused
        var thrown: DaemonLaunchError?
        do { try await launch.value } catch let error as DaemonLaunchError { thrown = error }
        #expect(thrown == .superseded)
        #expect(fixture.runCount == 0)
        #expect(fixture.process.state == .stopped)
    }

    /// The stop ladder's last rung: a daemon that ignores SIGTERM is SIGKILLed,
    /// and stop() still returns with the process down.
    @Test func stopEscalatesToSIGKILLWhenSIGTERMIgnored() async throws {
        let fixture = try StubDaemonFixture(script: Self.ignoreSIGTERM)
        defer { fixture.tearDown() }

        try await fixture.process.start()
        fixture.process.stop()
        #expect(fixture.process.state == .stopped)
    }

    // MARK: - Binary upgrade

    /// The upgrade sequence end to end at the process layer: stop, swap via
    /// the binary's own `upgrade` subcommand (run with nothing alive), start
    /// the NEW binary, and the previous one is there to discard — never a
    /// `.failed` along the way.
    @Test func upgradeSwapsBinaryWhileStoppedAndStartsTheNewOne() async throws {
        let fixture = try StubDaemonFixture(script: Self.upgradable(upgrade: Self.swapInPlace))
        defer { fixture.tearDown() }
        let asset = URL(string: "https://release.example/v9.9.9/syncthing-macos-arm64-v9.9.9.zip")!

        try await fixture.process.start()
        // `start()` resolves at the spawn; wait for the stub's first line so
        // the stop below can't SIGTERM it before it has run at all.
        try await expectEventually(timeout: 15) { fixture.runCount == 1 }
        #expect(await fixture.process.shutdown() != nil)

        let swap = try await fixture.process.upgradeBinary(from: asset)
        #expect(swap.binaryURL == fixture.binary)
        #expect(swap.hasPrevious)

        try await fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.runs == ["run", "upgrade", "run-new"] }
        #expect(!fixture.sawFailed)

        swap.discardPrevious()
        #expect(!swap.hasPrevious)
    }

    /// The swap requires a stopped daemon — Syncthing's `upgrade --from` does
    /// not check the instance lock, so it would rename the binary under a
    /// live process tree, the exact exposure the stopped swap exists to avoid.
    @Test func upgradeRefusesWhileDaemonRuns() async throws {
        let fixture = try StubDaemonFixture(script: Self.upgradable(upgrade: "exit 0"))
        defer { fixture.tearDown() }
        try await fixture.process.start()

        var thrown: SyncthingProcess.UpgradeError?
        do {
            _ = try await fixture.process.upgradeBinary(from: URL(string: "https://x/y.zip")!)
        } catch let error as SyncthingProcess.UpgradeError { thrown = error }
        #expect(thrown == .daemonRunning)
        try await expectEventually(timeout: 15) { fixture.runs == ["run"] }
    }

    /// An upgrader that fails reports its exit status, and the binary it was
    /// asked to replace is still the one on disk.
    @Test func upgradeReportsAFailedExit() async throws {
        let fixture = try StubDaemonFixture(script: Self.upgradable(upgrade: "echo nope >&2; exit 1"))
        defer { fixture.tearDown() }
        let before = try String(contentsOf: fixture.binary, encoding: .utf8)

        var thrown: SyncthingProcess.UpgradeError?
        do {
            _ = try await fixture.process.upgradeBinary(from: URL(string: "https://x/y.zip")!)
        } catch let error as SyncthingProcess.UpgradeError { thrown = error }
        #expect(thrown == .exited(code: 1))
        #expect(try String(contentsOf: fixture.binary, encoding: .utf8) == before)
    }

    /// An upgrader that hangs after renaming the binary away (the interrupted
    /// swap: killed between its two renames) is terminated at the timeout and
    /// the previous binary is put back — a runnable binary is always left.
    @Test func upgradeTimeoutRestoresThePreviousBinary() async throws {
        let fixture = try StubDaemonFixture(
            script: Self.upgradable(upgrade: "mv \"$0\" \"$0.old\"; exec sleep 1000"))
        defer { fixture.tearDown() }
        fixture.process.upgradeTimeout = 0.5
        let before = try String(contentsOf: fixture.binary, encoding: .utf8)
        let swap = BinarySwap(binaryURL: fixture.binary)

        var thrown: SyncthingProcess.UpgradeError?
        do {
            _ = try await fixture.process.upgradeBinary(from: URL(string: "https://x/y.zip")!)
        } catch let error as SyncthingProcess.UpgradeError { thrown = error }
        #expect(thrown == .timedOut(after: 0.5))
        #expect(swap.hasBinary)
        #expect(!swap.hasPrevious)
        #expect(try String(contentsOf: fixture.binary, encoding: .utf8) == before)

        // And the restored binary serves.
        try await fixture.process.start()
        #expect(fixture.isRunning)
    }

    // MARK: - Supersession and concurrency

    /// The launch token binds a start to the stop that preceded it: a stop
    /// that landed in between (a mode switch) makes the start refuse rather
    /// than spawn a daemon the app no longer expects — and the LAST stop's
    /// token is the live one.
    @Test func startAfterAnInterveningStopIsSuperseded() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }
        try await fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.runCount == 1 }

        let first = await fixture.process.shutdown()
        let second = await fixture.process.shutdown()   // e.g. a mode switch
        #expect(first != nil && second != nil && first != second)

        var thrown: DaemonLaunchError?
        do { try await fixture.process.start(after: first) } catch let error as DaemonLaunchError { thrown = error }
        #expect(thrown == .superseded)
        #expect(fixture.runCount == 1)
        #expect(fixture.process.state == .stopped)

        try await fixture.process.start(after: second)
        try await expectEventually(timeout: 15) { fixture.runCount == 2 }
    }

    /// A second `start()` while one is still preparing returns at once
    /// without touching the first: exactly one spawn, and the first caller's
    /// await resolves normally (the continuation slot is never overwritten).
    @Test func concurrentStartIsIgnoredWhileALaunchIsInProgress() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }
        let gate = DispatchSemaphore(value: 0)
        fixture.process.verifyBinary = { _ in gate.wait() }

        let first = Task { try await fixture.process.start() }
        try await expectEventually { fixture.process.state == .starting }

        try await fixture.process.start()   // returns immediately, no throw
        #expect(fixture.process.state == .starting)

        gate.signal()
        try await first.value
        #expect(fixture.isRunning)
        try await expectEventually(timeout: 15) { fixture.runCount == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fixture.runCount == 1)
    }

    /// Concurrent `shutdown()` calls share one ladder: both resolve once the
    /// daemon is down, the daemon was stopped once, and the state settles on
    /// `.stopped` without a `.failed` detour.
    @Test func concurrentShutdownsShareOneLadder() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }
        try await fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.runCount == 1 }

        async let a = fixture.process.shutdown()
        async let b = fixture.process.shutdown()
        let (ta, tb) = await (a, b)
        #expect(ta != nil && tb != nil)
        #expect(fixture.process.state == .stopped)
        #expect(!fixture.sawFailed)
    }

    /// The REST rung is waited only while the request stands: with no
    /// listener at the configured address the request is refused at once,
    /// and the ladder falls through to SIGTERM long before the REST grace.
    @Test func refusedRestShutdownFallsThroughToSIGTERMImmediately() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }
        fixture.process.shutdownGraces = (rest: 30, term: 0.5)
        try await fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.runCount == 1 }

        let started = Date()
        #expect(await fixture.process.shutdown() != nil)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(fixture.process.state == .stopped)
    }

    /// A terminal `stop()` lets an in-flight one-shot run finish on its own
    /// within the quit grace, so a completing swap is never torn by the quit.
    @Test func stopWaitsForAnInFlightCommandToFinish() async throws {
        let fixture = try StubDaemonFixture(
            script: Self.upgradable(upgrade: "sleep 0.5; echo upgrade-done >> RUNS; exit 0"))
        defer { fixture.tearDown() }
        fixture.process.commandQuitGrace = 5

        let upgrade = Task { try await fixture.process.upgradeBinary(from: URL(string: "https://x/y.zip")!) }
        try await expectEventually(timeout: 15) { fixture.runs.contains("upgrade") }

        fixture.process.stop()   // blocks until the run is gone
        #expect(fixture.runs.contains("upgrade-done"))
        _ = try? await upgrade.value
    }

    /// Past the quit grace the run is terminated and `stop()` still returns
    /// with the child gone.
    @Test func stopTerminatesAnInFlightCommandPastTheQuitGrace() async throws {
        let fixture = try StubDaemonFixture(
            script: Self.upgradable(upgrade: "echo $$ > RUNS.cmd; exec sleep 1000"))
        defer { fixture.tearDown() }
        fixture.process.commandQuitGrace = 0.3

        let upgrade = Task { try await fixture.process.upgradeBinary(from: URL(string: "https://x/y.zip")!) }
        let pidFile = fixture.runsFile.path + ".cmd"
        try await expectEventually(timeout: 15) { FileManager.default.fileExists(atPath: pidFile) }
        let child = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!

        fixture.process.stop()
        #expect(kill(child, 0) == -1)
        _ = try? await upgrade.value
    }
}
