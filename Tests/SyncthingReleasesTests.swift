import Testing
@testable import SyncthingMenu

/// The port-verification of `SyncthingReleases`, made permanent. The tables here
/// are Syncthing's own, ported verbatim from `lib/upgrade/upgrade_test.go` at
/// v2.1.1 — the exact version the production code was ported from. The daemon
/// re-resolves the release itself at install time (`POST /rest/system/upgrade`),
/// so a divergence between our check and its logic surfaces the wrong version to
/// the user; these tests keep the field-for-field port field-for-field.
struct SyncthingReleasesTests {

    typealias Relation = SyncthingReleases.Relation

    // MARK: - CompareVersions (upstream `versions` table, 31 cases)

    private static let compareCases: [(a: String, b: String, expected: Relation)] = [
        ("0.1.2", "0.1.2", .equal),
        ("0.1.3", "0.1.2", .newer),
        ("0.1.1", "0.1.2", .older),
        ("0.3.0", "0.1.2", .newer),
        ("0.0.9", "0.1.2", .older),
        ("1.3.0", "1.1.2", .newer),
        ("1.0.9", "1.1.2", .older),
        ("2.3.0", "1.1.2", .majorNewer),
        ("1.0.9", "2.1.2", .majorOlder),
        ("1.1.2", "0.1.2", .newer),        // v0.x and v1.x are equivalent in majorness
        ("0.1.2", "1.1.2", .older),
        ("2.1.2", "0.1.2", .majorNewer),
        ("0.1.2", "2.1.2", .majorOlder),
        ("0.1.10", "0.1.9", .newer),
        ("0.10.0", "0.2.0", .newer),
        ("30.10.0", "4.9.0", .majorNewer),
        ("0.9.0-beta7", "0.9.0-beta6", .newer),
        ("0.9.0-beta7", "1.0.0-alpha", .older),
        ("1.0.0-alpha", "1.0.0-alpha.1", .older),
        ("1.0.0-alpha.1", "1.0.0-alpha.beta", .older),
        ("1.0.0-alpha.beta", "1.0.0-beta", .older),
        ("1.0.0-beta", "1.0.0-beta.2", .older),
        ("1.0.0-beta.2", "1.0.0-beta.11", .older),
        ("1.0.0-beta.11", "1.0.0-rc.1", .older),
        ("1.0.0-rc.1", "1.0.0", .older),
        ("1.0.0+45", "1.0.0+23-dev-foo", .equal),
        ("1.0.0-beta.23+45", "1.0.0-beta.23+23-dev-foo", .equal),
        ("1.0.0-beta.3+99", "1.0.0-beta.24+0", .older),
        ("v1.1.2", "1.1.2", .equal),
        ("v1.1.2", "V1.1.2", .equal),
        ("1.1.2", "V1.1.2", .equal),
    ]

    @Test(arguments: compareCases)
    func compareVersionsMatchesUpstream(_ tc: (a: String, b: String, expected: Relation)) {
        #expect(SyncthingReleases.compareVersions(tc.a, tc.b) == tc.expected)
    }

    // MARK: - SelectLatestRelease (upstream `TestSelectedRelease` table, 11 cases)

    private static let selectionCases: [(current: String, upgradeToPre: Bool,
                                         candidates: [String], selected: String)] = [
        // Within the same "major" (minor, in this case) select the newest
        ("v0.12.24", false, ["v0.12.23", "v0.12.24", "v0.12.25", "v0.12.26"], "v0.12.26"),
        ("v0.12.24", false, ["v0.12.23", "v0.12.24", "v0.12.25", "v0.13.0"], "v0.13.0"),
        ("v0.12.24", false, ["v0.12.23", "v0.12.24", "v0.12.25", "v1.0.0"], "v1.0.0"),
        // Do not select beta versions when we are not allowed to
        ("v0.12.24", false, ["v0.12.26", "v0.12.27-beta.42"], "v0.12.26"),
        ("v0.12.24-beta.0", false, ["v0.12.26", "v0.12.27-beta.42"], "v0.12.26"),
        // Do select beta versions when we can
        ("v0.12.24", true, ["v0.12.26", "v0.12.27-beta.42"], "v0.12.27-beta.42"),
        ("v0.12.24-beta.0", true, ["v0.12.26", "v0.12.27-beta.42"], "v0.12.27-beta.42"),
        // Select the best within the current major when there is a minor upgrade available
        ("v0.12.24", false, ["v1.12.23", "v1.12.24", "v1.14.2", "v2.0.0"], "v1.14.2"),
        ("v1.12.24", false, ["v1.12.23", "v1.12.24", "v1.14.2", "v2.0.0"], "v1.14.2"),
        // Select the next major when we are at the best minor
        ("v0.12.25", true, ["v0.12.23", "v0.12.24", "v0.12.25", "v0.13.0"], "v0.13.0"),
        ("v1.14.2", true, ["v0.12.23", "v0.12.24", "v1.14.2", "v2.0.0"], "v2.0.0"),
    ]

    private static func release(_ tag: String, assetName: String) -> SyncthingReleases.Release {
        .init(tag: tag, prerelease: tag.contains("-"), assets: [.init(name: assetName)])
    }

    @Test(arguments: selectionCases)
    func selectionMatchesUpstream(_ tc: (current: String, upgradeToPre: Bool,
                                         candidates: [String], selected: String)) throws {
        let releases = tc.candidates.map {
            Self.release($0, assetName: "syncthing-macos-arm64-\($0).tar.gz")
        }
        let selected = try SyncthingReleases.selectLatestRelease(
            releases, current: tc.current,
            upgradeToPreReleases: tc.upgradeToPre, arch: "arm64")
        #expect(selected.tag == tc.selected)
    }

    /// Upstream `TestErrorRelease`: an empty feed is an error, not a nil.
    @Test func emptyFeedThrows() {
        #expect(throws: SyncthingReleases.FeedError.noApplicableRelease) {
            try SyncthingReleases.selectLatestRelease(
                [], current: "v0.11.0-beta", upgradeToPreReleases: false, arch: "arm64")
        }
    }

    /// Upstream `TestSelectedReleaseMacOS`: both historical macOS asset spellings
    /// ("macos" and "macosx") must be recognized.
    @Test(arguments: ["syncthing-macos-arm64-v0.14.47.tar.gz",
                      "syncthing-macosx-arm64-v0.14.47.tar.gz"])
    func acceptsBothMacOSAssetSpellings(assetName: String) throws {
        let selected = try SyncthingReleases.selectLatestRelease(
            [Self.release("v0.14.47", assetName: assetName)],
            current: "v0.14.46", upgradeToPreReleases: false, arch: "arm64")
        #expect(selected.tag == "v0.14.47")
    }

    /// A release with no asset for this OS/arch must not be selected — the
    /// "matching asset" rule the selection table relies on, checked negatively.
    @Test func ignoresReleasesForOtherPlatforms(){
        let releases = [
            Self.release("v0.14.47", assetName: "syncthing-linux-amd64-v0.14.47.tar.gz"),
            Self.release("v0.14.48", assetName: "syncthing-macos-amd64-v0.14.48.tar.gz"),
        ]
        #expect(throws: SyncthingReleases.FeedError.noApplicableRelease) {
            try SyncthingReleases.selectLatestRelease(
                releases, current: "v0.14.46", upgradeToPreReleases: false, arch: "arm64")
        }
    }
}
