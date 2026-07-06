import Foundation
import CryptoKit

/// Downloads the official Syncthing macOS binary from GitHub Releases, verifies
/// its SHA-256, and installs it into the app's private support directory — the
/// initial "bootstrap". Ongoing updates are handled by the daemon itself (via its
/// REST upgrade API), not here.
///
/// NOTE (first slice): this verifies the SHA-256 published in `sha256sum.txt.asc`.
/// Verifying that file's *GPG signature* against Syncthing's release key is a
/// planned hardening step — see TODO below.
struct ReleaseUpdater {
    enum BootstrapError: Error {
        case noUniversalAsset
        case noChecksumAsset
        case checksumNotFound
        case checksumMismatch(expected: String, actual: String)
        case binaryNotFoundInArchive
    }

    /// Where the managed Syncthing binary lives.
    static var installedBinaryURL: URL {
        appSupportDirectory().appendingPathComponent("bin/syncthing")
    }

    private static let releasesAPI =
        URL(string: "https://api.github.com/repos/syncthing/syncthing/releases/latest")!

    /// Install the latest Syncthing binary if it isn't already present.
    @discardableResult
    func bootstrapIfNeeded() async throws -> URL {
        let target = Self.installedBinaryURL
        if FileManager.default.isExecutableFile(atPath: target.path) {
            return target
        }
        return try await bootstrap()
    }

    /// Download + verify + install the latest release, unconditionally.
    @discardableResult
    func bootstrap() async throws -> URL {
        let release = try await fetchLatestRelease()

        guard let zipAsset = release.assets.first(where: {
            $0.name.hasPrefix("syncthing-macos-universal-") && $0.name.hasSuffix(".zip")
        }) else { throw BootstrapError.noUniversalAsset }

        guard let sumAsset = release.assets.first(where: { $0.name == "sha256sum.txt.asc" }) else {
            throw BootstrapError.noChecksumAsset
        }

        let (zipData, _) = try await URLSession.shared.data(from: zipAsset.downloadURL)
        let (sumData, _) = try await URLSession.shared.data(from: sumAsset.downloadURL)

        // TODO (hardening): verify the GPG signature of sha256sum.txt.asc against
        // Syncthing's pinned release public key before trusting its contents.
        let expected = try Self.expectedSHA256(forAsset: zipAsset.name, in: sumData)
        let actual = Self.sha256Hex(of: zipData)
        guard actual == expected else {
            throw BootstrapError.checksumMismatch(expected: expected, actual: actual)
        }

        let installed = try Self.installBinary(fromZip: zipData)
        NSLog("ReleaseUpdater: installed Syncthing \(release.tag) at \(installed.path)")
        return installed
    }

    // MARK: - Release metadata

    private struct Release {
        let tag: String
        let assets: [Asset]
    }
    private struct Asset {
        let name: String
        let downloadURL: URL
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: Self.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct APIRelease: Decodable {
            let tag_name: String
            let assets: [APIAsset]
        }
        struct APIAsset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let decoded = try JSONDecoder().decode(APIRelease.self, from: data)
        return Release(tag: decoded.tag_name,
                       assets: decoded.assets.map {
                           Asset(name: $0.name, downloadURL: $0.browser_download_url)
                       })
    }

    // MARK: - Checksum

    /// Parse the SHA-256 for `assetName` out of the clear-signed sha256sum file.
    /// Hash lines look like: "<64-hex>  syncthing-macos-universal-vX.Y.Z.zip".
    /// PGP header/signature lines don't have exactly two whitespace-separated
    /// fields, so they're skipped.
    static func expectedSHA256(forAsset assetName: String, in sumData: Data) throws -> String {
        guard let text = String(data: sumData, encoding: .utf8) else {
            throw BootstrapError.checksumNotFound
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == assetName {
                return parts[0].lowercased()
            }
        }
        throw BootstrapError.checksumNotFound
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install

    private static func installBinary(fromZip zipData: Data) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let zipURL = tmp.appendingPathComponent("syncthing.zip")
        try zipData.write(to: zipURL)

        let extractDir = tmp.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runDitto(unzip: zipURL, into: extractDir)

        guard let binary = findFile(named: "syncthing", under: extractDir) else {
            throw BootstrapError.binaryNotFoundInArchive
        }

        let dest = installedBinaryURL
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: binary, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    private static func runDitto(unzip zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        try process.run()
        process.waitUntilExit()
    }

    private static func findFile(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    private static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Syncthing Menu", isDirectory: true)
    }
}
