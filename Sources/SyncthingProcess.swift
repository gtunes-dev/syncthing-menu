import Foundation
import Darwin

/// Launches and supervises the managed Syncthing daemon as a child process.
///
/// Runs an *isolated* instance: its own home directory (config + database) under
/// our app-support directory. We **never write Syncthing's `config.xml`** — we let
/// Syncthing pick free GUI/listen ports (it does this itself), read the API key it
/// generated, and pin the GUI port via a CLI flag using a value persisted on *our*
/// side. The one option we enforce (`autoUpgradeIntervalH = 0`) is applied later via
/// the REST API (B3), not by editing the file.
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

    /// The daemon's API key, read from `config.xml` once running. Used by the
    /// (forthcoming) REST client.
    private(set) var apiKey: String?

    private let binaryURL: URL
    private let homeURL: URL
    private var pid: pid_t?
    private var stdoutHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var intentionalStop = false

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
        guard pid == nil else { return }
        state = .starting
        intentionalStop = false

        // Generate (first run) can block briefly, so do prep off-main; the actual
        // launch returns to main to keep process state consistent.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let plan = try self.prepareLaunch()
                DispatchQueue.main.async { self.launchServe(plan: plan) }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed("Setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stop the daemon cleanly (SIGTERM) and wait for it to exit (SIGKILL after 5s).
    func stop() {
        guard let pid = self.pid else { return }
        intentionalStop = true
        // We reap synchronously below, so cancel the async exit watcher first.
        exitSource?.cancel()
        exitSource = nil

        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }                       // reaped
            if r == -1 && errno != EINTR { break }      // already gone / error
            if Date() >= deadline {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                break
            }
            usleep(50_000)
        }

        self.pid = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
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

        var envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
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
            if !self.intentionalStop {
                // TODO (B4): restart with backoff on unexpected exit.
                self.state = .failed("Syncthing exited (\(Self.describe(status)))")
            }
        }
        source.resume()
        exitSource = source
        pid = newPid

        apiKey = plan.apiKey
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
