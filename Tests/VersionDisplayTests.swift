import Testing
@testable import SyncthingMenu

/// Version-string presentation rules (decided 2026-07-07): versions display as
/// bare semver everywhere — the daemon API's "v" is Git-tag orthography, stripped
/// once at the `SyncthingUpdateSource` boundary — while `ReleaseNotes` normalizes
/// to exactly one leading "v" for GitHub tag URLs, so links work from either form.
struct VersionDisplayTests {

    // MARK: - ReleaseNotes tag URLs

    @Test func appReleaseNotesURL() {
        #expect(ReleaseNotes.app(version: "0.1.2")?.absoluteString
            == "https://github.com/gtunes-dev/syncthing-menu/releases/tag/v0.1.2")
    }

    @Test(arguments: ["2.1.1", "v2.1.1", "V2.1.1", " v2.1.1 "])
    func syncthingURLNormalizesToOneLeadingV(_ version: String) {
        #expect(ReleaseNotes.syncthing(version: version)?.absoluteString
            == "https://github.com/syncthing/syncthing/releases/tag/v2.1.1")
    }

    /// Placeholders and non-versions yield nil so callers omit the link entirely.
    @Test(arguments: ["—", "", "unknown", "v"])
    func nonVersionsYieldNoURL(_ version: String) {
        #expect(ReleaseNotes.app(version: version) == nil)
    }

    // MARK: - Daemon version display

    @Test(arguments: [("v2.1.1", "2.1.1"), ("2.1.1", "2.1.1"), ("V2.1.1", "2.1.1")])
    func displayVersionStripsTagPrefix(_ tc: (raw: String, display: String)) {
        #expect(SyncthingUpdateSource.displayVersion(tc.raw) == tc.display)
    }
}
