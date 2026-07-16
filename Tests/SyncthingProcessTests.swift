import Foundation
import Testing
@testable import SyncthingMenu

/// A scripted stand-in for the syncthing binary plus an isolated home directory.
/// The process layer spawns it exactly like the real daemon (posix_spawn, pipes,
/// exit watcher), so these are integration tests of real process mechanics —
/// only the *behavior* of the child is scripted per test.
@MainActor
private final class StubDaemonFixture {
    let dir: URL
    let runsFile: URL
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
        let binary = dir.appendingPathComponent("syncthing")
        try script.replacingOccurrences(of: "RUNS", with: runsFile.path)
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)

        process = SyncthingProcess(binaryURL: binary, homeURL: home)
        process.escalationGrace = 0.2
        process.onStateChange = { [weak self] in self?.states.append($0) }
    }

    var isRunning: Bool { if case .running = process.state { return true } else { return false } }
    var isFailed: Bool { if case .failed = process.state { return true } else { return false } }

    /// How many times the stub was spawned (scripts append one line per run).
    var runCount: Int {
        ((try? String(contentsOf: runsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
    }

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

    /// An unexpected exit surfaces as `.failed` with the exit reason, and
    /// deliberately does not respawn — detection without remediation is the
    /// decided behavior (worker crashes are Syncthing's own monitor's job).
    @Test func unexpectedExitFailsWithoutRespawning() async throws {
        let fixture = try StubDaemonFixture(script: Self.crashOnce)
        defer { fixture.tearDown() }

        fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.isFailed }
        guard case let .failed(message) = fixture.process.state else { return }
        #expect(message.contains("code 7"))

        // No supervision kicks in: one spawn, ever.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(fixture.runCount == 1)
        #expect(fixture.isFailed)
    }

    /// A planned restart (the post-upgrade re-root) stops the old daemon and
    /// spawns a fresh one, without ever passing through `.failed` — the exit
    /// watcher is cancelled by `beginStop()`, so the deliberate stop is never
    /// mistaken for a crash.
    @Test func plannedRestartSpawnsFreshDaemon() async throws {
        let fixture = try StubDaemonFixture(script: Self.stayAlive)
        defer { fixture.tearDown() }

        fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.isRunning && fixture.runCount == 1 }

        fixture.process.restart()
        try await expectEventually(timeout: 15) { fixture.isRunning && fixture.runCount == 2 }
        #expect(!fixture.states.contains { if case .failed = $0 { return true } else { return false } })
    }

    /// The stop ladder's last rung: a daemon that ignores SIGTERM is SIGKILLed,
    /// and stop() still returns with the process down.
    @Test func stopEscalatesToSIGKILLWhenSIGTERMIgnored() async throws {
        let fixture = try StubDaemonFixture(script: Self.ignoreSIGTERM)
        defer { fixture.tearDown() }

        fixture.process.start()
        try await expectEventually(timeout: 15) { fixture.isRunning }

        fixture.process.stop()
        #expect(fixture.process.state == .stopped)
    }
}
