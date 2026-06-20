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
    private var process: Process?
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
        guard process == nil else { return }
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

    /// Stop the daemon cleanly (SIGTERM) and wait for it to exit.
    func stop() {
        guard let proc = process else { return }
        intentionalStop = true
        proc.terminate()
        proc.waitUntilExit()
        process = nil
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
        let proc = Process()
        proc.executableURL = binaryURL
        var args = ["serve", "--home", homeURL.path, "--no-browser"]
        if let override = plan.guiAddressOverride {
            args += ["--gui-address", override]
        }
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[syncthing] \(text.trimmingCharacters(in: .newlines))")
        }

        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.process = nil
                if self.intentionalStop {
                    self.state = .stopped
                } else {
                    // TODO (B4): restart with backoff on unexpected exit.
                    self.state = .failed("Syncthing exited (code \(finished.terminationStatus))")
                }
            }
        }

        do {
            try proc.run()
            process = proc
            apiKey = plan.apiKey
            state = .running(guiURL: plan.guiURL)
            NSLog("Syncthing daemon started at \(plan.guiURL) (home: \(homeURL.path))")
        } catch {
            state = .failed("Couldn't launch Syncthing: \(error.localizedDescription)")
        }
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
