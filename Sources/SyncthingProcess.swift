import Foundation
import Darwin

/// Launches and supervises the managed Syncthing daemon as a child process.
///
/// Runs an *isolated* instance: its own home directory (config + database) under
/// our app-support directory, on its own GUI port, so it never collides with any
/// other Syncthing the user may be running.
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

    private let binaryURL: URL
    private let homeURL: URL
    private var process: Process?
    private var intentionalStop = false

    init(binaryURL: URL = ReleaseUpdater.installedBinaryURL,
         homeURL: URL = SyncthingProcess.defaultHomeURL) {
        self.binaryURL = binaryURL
        self.homeURL = homeURL
    }

    static var defaultHomeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Syncthing Menu/home", isDirectory: true)
    }

    /// Launch the daemon. Safe to call once; no-op if already running.
    func start() {
        guard process == nil else { return }
        state = .starting
        intentionalStop = false

        do {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        } catch {
            state = .failed("Couldn't create home dir: \(error.localizedDescription)")
            return
        }

        let guiAddress = "127.0.0.1:\(Self.chooseGUIPort())"
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = [
            "serve",
            "--home", homeURL.path,
            "--no-browser",
            "--gui-address", guiAddress,
        ]

        // Mirror the daemon's stdout/stderr into the log for now (status/UI wiring
        // beyond the menu line comes later).
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
            state = .running(guiURL: "http://\(guiAddress)")
            NSLog("Syncthing daemon started at http://\(guiAddress) (home: \(homeURL.path))")
        } catch {
            state = .failed("Couldn't launch Syncthing: \(error.localizedDescription)")
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

    // MARK: - Port selection

    /// Prefer Syncthing's default GUI port; fall back to a free ephemeral port if
    /// it's already taken (e.g. another Syncthing is running). Ships as 8384 for a
    /// sole instance; auto-dodges conflicts during development.
    private static func chooseGUIPort() -> UInt16 {
        let preferred: UInt16 = 8384
        return isPortFree(preferred) ? preferred : (findFreePort() ?? 8385)
    }

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
