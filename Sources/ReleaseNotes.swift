import Foundation

/// Builds links to the GitHub release-notes page for a given version of either
/// component. Both projects publish a page per version at `/releases/tag/v<semver>`,
/// so the URL derives from the version string alone (normalized to exactly one
/// leading `v`). Used for the "Release Notes" links beside a current version (About)
/// and a pending update (Settings).
enum ReleaseNotes {
    private static let appRepo = "https://github.com/gtunes-dev/syncthing-menu"
    private static let syncthingRepo = "https://github.com/syncthing/syncthing"

    /// Release-notes page for a Syncthing Menu (app) version, e.g. "0.1.2".
    static func app(version: String) -> URL? { url(repo: appRepo, version: version) }

    /// Release-notes page for a Syncthing daemon version, e.g. "v2.1.1".
    static func syncthing(version: String) -> URL? { url(repo: syncthingRepo, version: version) }

    /// `<repo>/releases/tag/v<semver>`, normalizing the version to one leading `v`.
    /// Returns nil for non-version strings (e.g. a "—" placeholder), so callers can
    /// simply omit the link when this is nil.
    private static func url(repo: String, version: String) -> URL? {
        let core = version.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "v" || $0 == "V" })
        guard let first = core.first, first.isNumber else { return nil }
        return URL(string: "\(repo)/releases/tag/v\(core)")
    }
}
