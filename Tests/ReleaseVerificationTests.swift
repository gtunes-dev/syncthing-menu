import Foundation
import Testing
@testable import SyncthingMenu

/// The code-signature gate. The *mechanism* is tested here against Apple-signed
/// system binaries (present on every Mac and CI runner); the pinned Kastelo
/// requirement itself was verified against the real installed syncthing binary
/// (accepts it; rejects /bin/ls) — a positive fixture CI can't carry.
struct BinaryVerifierTests {

    @Test func acceptsBinaryMatchingRequirement() throws {
        try BinaryVerifier.verify(url: URL(fileURLWithPath: "/bin/ls"),
                                  requirement: "anchor apple")
    }

    /// An Apple-signed binary is valid code — but not Syncthing's: the pinned
    /// requirement must reject it.
    @Test func rejectsBinaryFromAnotherTeam() {
        #expect(throws: BinaryVerifier.VerificationError.self) {
            try BinaryVerifier.verifySyncthingBinary(at: URL(fileURLWithPath: "/bin/ls"))
        }
    }

    @Test func rejectsUnsignedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsigned-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BinaryVerifier.VerificationError.self) {
            try BinaryVerifier.verifySyncthingBinary(at: url)
        }
    }

    @Test func detectsQuarantineFlag() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantined-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!BinaryVerifier.isQuarantined(at: url))

        let value = "0083;00000000;Safari;"
        try #require(setxattr(url.path, "com.apple.quarantine",
                              value, value.utf8.count, 0, 0) == 0)
        #expect(BinaryVerifier.isQuarantined(at: url))
    }
}

/// The sha256sum.txt.asc parser: hash lines amid PGP armor.
struct ChecksumParsingTests {

    private static let sample = """
    -----BEGIN PGP SIGNED MESSAGE-----
    Hash: SHA256

    0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9  syncthing-linux-amd64-v2.1.2.tar.gz
    ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100  syncthing-macos-universal-v2.1.2.zip
    -----BEGIN PGP SIGNATURE-----

    iQEzBAEBCAAdFiEE
    -----END PGP SIGNATURE-----
    """

    @Test func extractsHashForNamedAsset() throws {
        let hash = try ReleaseUpdater.expectedSHA256(
            forAsset: "syncthing-macos-universal-v2.1.2.zip",
            in: Data(Self.sample.utf8))
        #expect(hash == "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
    }

    @Test func missingAssetThrows() {
        #expect(throws: ReleaseUpdater.BootstrapError.checksumNotFound) {
            try ReleaseUpdater.expectedSHA256(forAsset: "syncthing-windows-amd64-v2.1.2.zip",
                                              in: Data(Self.sample.utf8))
        }
    }
}
