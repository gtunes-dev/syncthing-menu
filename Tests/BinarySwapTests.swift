import Foundation
import Testing
@testable import SyncthingMenu

/// The on-disk swap Syncthing's upgrader performs and the recoveries layered on
/// it. A scratch directory stands in for `bin/`; file contents identify which
/// "binary" is where.
struct BinarySwapTests {
    private struct Scratch {
        let dir: URL
        let swap: BinarySwap

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("BinarySwapTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            swap = BinarySwap(binaryURL: dir.appendingPathComponent("syncthing"))
        }

        func write(_ content: String, to url: URL) throws {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        func tearDown() { try? FileManager.default.removeItem(at: dir) }
    }

    /// A completed swap (binary + .old) needs no recovery and is left alone.
    @Test func completedSwapIsLeftAlone() throws {
        let s = try Scratch()
        defer { s.tearDown() }
        try s.write("new", to: s.swap.binaryURL)
        try s.write("old", to: s.swap.previousURL)

        #expect(!s.swap.recoverIfInterrupted())
        #expect(s.read(s.swap.binaryURL) == "new")
        #expect(s.read(s.swap.previousURL) == "old")
    }

    /// Killed between the upgrader's two renames: only `.old` remains, plus
    /// the temp download (`syncthing<digits>`). The previous binary is put
    /// back and the download swept; unrelated files are untouched.
    @Test func interruptedSwapRestoresPreviousAndSweepsDownload() throws {
        let s = try Scratch()
        defer { s.tearDown() }
        try s.write("old", to: s.swap.previousURL)
        try s.write("partial", to: s.dir.appendingPathComponent("syncthing123456789"))
        try s.write("keep", to: s.dir.appendingPathComponent("syncthing.log"))

        #expect(s.swap.recoverIfInterrupted())
        #expect(s.read(s.swap.binaryURL) == "old")
        #expect(!s.swap.hasPrevious)
        #expect(!s.exists("syncthing123456789"))
        #expect(s.exists("syncthing.log"))
    }

    /// Nothing to recover from (a fresh install, or a wiped directory) is not
    /// an error — the bootstrap handles the missing binary.
    @Test func nothingToRecoverIsANoOp() throws {
        let s = try Scratch()
        defer { s.tearDown() }
        #expect(!s.swap.recoverIfInterrupted())
        #expect(!s.swap.hasBinary)
    }

    /// Discarding the previous binary is idempotent and never touches the
    /// current one.
    @Test func discardPreviousIsIdempotent() throws {
        let s = try Scratch()
        defer { s.tearDown() }
        try s.write("new", to: s.swap.binaryURL)
        try s.write("old", to: s.swap.previousURL)

        s.swap.discardPrevious()
        s.swap.discardPrevious()
        #expect(!s.swap.hasPrevious)
        #expect(s.read(s.swap.binaryURL) == "new")
    }
}
