import Foundation
import Testing
@testable import SyncthingMenu

/// The feed's asset shape as the install sees it: selection is by name and
/// never depends on a URL; the install needs a URL the release signature can
/// verify, which means one ending in the asset's file name.
struct SyncthingReleaseAssetTests {
    private func decode(_ json: String) throws -> [SyncthingReleases.Release] {
        try JSONDecoder().decode([SyncthingReleases.Release].self, from: Data(json.utf8))
    }

    /// The upgrade feed's shape: `url` ends in the file name.
    @Test func feedURLEndingInTheAssetNameIsInstallable() throws {
        let releases = try decode("""
        [{"tag_name":"v2.1.5","prerelease":false,"assets":[
          {"name":"syncthing-macos-arm64-v2.1.5.zip",
           "url":"https://release.syncthingcdn.net/v2.1.5/syncthing-macos-arm64-v2.1.5.zip"}]}]
        """)
        let asset = try #require(SyncthingReleases.upgradeAsset(of: releases[0], arch: "arm64"))
        #expect(asset.downloadURL?.absoluteString
                == "https://release.syncthingcdn.net/v2.1.5/syncthing-macos-arm64-v2.1.5.zip")
    }

    /// A feed entry without any URL still decodes and still counts for
    /// selection; it is simply not installable.
    @Test func assetWithoutURLDecodesAndSelectsButIsNotInstallable() throws {
        let releases = try decode("""
        [{"tag_name":"v2.1.5","prerelease":false,"assets":[
          {"name":"syncthing-macos-arm64-v2.1.5.zip"}]}]
        """)
        let selected = try SyncthingReleases.selectLatestRelease(
            releases, current: "v2.1.3", upgradeToPreReleases: false, arch: "arm64")
        #expect(selected.tag == "v2.1.5")
        let asset = try #require(SyncthingReleases.upgradeAsset(of: selected, arch: "arm64"))
        #expect(asset.downloadURL == nil)
    }

    /// The GitHub API's shape: `url` is an API endpoint (not a file name), and
    /// `browser_download_url` is the one that verifies.
    @Test func gitHubAPIShapeUsesTheBrowserDownloadURL() throws {
        let releases = try decode("""
        [{"tag_name":"v2.1.5","prerelease":false,"assets":[
          {"name":"syncthing-macos-arm64-v2.1.5.zip",
           "url":"https://api.github.com/repos/syncthing/syncthing/releases/assets/12345",
           "browser_download_url":"https://github.com/syncthing/syncthing/releases/download/v2.1.5/syncthing-macos-arm64-v2.1.5.zip"}]}]
        """)
        let asset = try #require(SyncthingReleases.upgradeAsset(of: releases[0], arch: "arm64"))
        #expect(asset.downloadURL?.lastPathComponent == "syncthing-macos-arm64-v2.1.5.zip")
        #expect(asset.downloadURL?.host == "github.com")
    }

    /// A URL that doesn't end in the file name can never verify, whichever
    /// field it came from.
    @Test func urlNotEndingInTheAssetNameIsNotInstallable() throws {
        let releases = try decode("""
        [{"tag_name":"v2.1.5","prerelease":false,"assets":[
          {"name":"syncthing-macos-arm64-v2.1.5.zip",
           "url":"https://example.invalid/download?id=12345"}]}]
        """)
        let asset = try #require(SyncthingReleases.upgradeAsset(of: releases[0], arch: "arm64"))
        #expect(asset.downloadURL == nil)
    }
}
