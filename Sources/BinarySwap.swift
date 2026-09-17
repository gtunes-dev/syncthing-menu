import Foundation

/// The on-disk swap Syncthing's own upgrader performs beside the binary — the
/// current `syncthing` is renamed to `syncthing.old` and the verified download
/// takes its place — plus the recoveries this app layers on top of it. Pure
/// file operations keyed on the binary's location; nothing here knows about
/// processes. `SyncthingProcess.upgradeBinary(from:)` returns one as the
/// receipt of a swap, and the update mechanism uses it to discard the previous
/// binary once the new one is confirmed.
struct BinarySwap: Equatable {
    let binaryURL: URL

    /// Where Syncthing parks the previous binary (`syncthing.old`).
    var previousURL: URL { binaryURL.appendingPathExtension("old") }

    var hasPrevious: Bool { FileManager.default.fileExists(atPath: previousURL.path) }
    var hasBinary: Bool { FileManager.default.fileExists(atPath: binaryURL.path) }

    /// Repair the aftermath of an upgrade interrupted mid-swap (the `syncthing
    /// upgrade` process killed by a quit or by our timeout — Go runs no
    /// deferred cleanup on a signal). Between its two renames there is no
    /// `syncthing`, only `syncthing.old`: put the previous binary back. Either
    /// way, sweep the partially downloaded temp files it leaves beside the
    /// binary. Returns whether the previous binary was restored.
    @discardableResult
    func recoverIfInterrupted() -> Bool {
        sweepStaleDownloads()
        guard !hasBinary, hasPrevious else { return false }
        do {
            try FileManager.default.moveItem(at: previousURL, to: binaryURL)
            return true
        } catch {
            Log.process.error("couldn't restore \(self.binaryURL.lastPathComponent, privacy: .public) from .old: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Drop the previous binary once the new one is confirmed working. A
    /// failure here is cosmetic (Syncthing's next upgrade removes it too), so
    /// it is logged, not thrown.
    func discardPrevious() {
        guard hasPrevious else { return }
        do {
            try FileManager.default.removeItem(at: previousURL)
        } catch {
            Log.process.log("couldn't remove \(self.previousURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Syncthing downloads into `CreateTemp(dir, "syncthing")` — the binary's
    /// name followed by random digits. Anything of that shape beside the
    /// binary is a download that never finished.
    private func sweepStaleDownloads() {
        let fm = FileManager.default
        let dir = binaryURL.deletingLastPathComponent()
        let prefix = binaryURL.lastPathComponent
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { continue }
            try? fm.removeItem(at: dir.appendingPathComponent(name))
            Log.process.log("removed interrupted download \(name, privacy: .public)")
        }
    }
}
