import Foundation

/// Client-side replica of the Syncthing daemon's own upgrade check.
///
/// We launch the daemon with `STNOUPGRADE=1` so its Web UI never advertises
/// upgrades (Syncthing Menu owns the update flow). That flag also disables the
/// daemon's `GET /rest/system/upgrade`, so availability must be determined here:
/// fetch the same releases feed the daemon uses (`releasesURL`, GitHub-releases
/// shaped JSON) and apply the same selection and version-comparison rules. The
/// *install* still goes through `POST /rest/system/upgrade` (unaffected by the
/// flag), where the daemon re-resolves the release itself and SHA-verifies the
/// download — a divergence here can surface the wrong version, never install it.
///
/// Ported from `lib/upgrade` at syncthing v2.1.1 (`CompareVersions`,
/// `SelectLatestRelease`, `releaseNames`); the port is field-for-field so the two
/// sides keep agreeing on "what's the latest applicable release".
enum SyncthingReleases {

    // MARK: - Feed

    /// One release from the feed. Only the fields the selection logic reads.
    struct Release: Decodable, Equatable {
        let tag: String
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable, Equatable {
            let name: String
        }

        private enum CodingKeys: String, CodingKey {
            case tag = "tag_name", prerelease, assets
        }
    }

    enum FeedError: Error {
        case http(Int)
        /// No release in the feed carries an asset for this OS/architecture.
        case noApplicableRelease
    }

    /// Fetch the releases feed (the daemon's `releasesURL`, normally
    /// `https://upgrades.syncthing.net/meta.json`). Plain unauthenticated GET —
    /// this is an external service, not the daemon.
    static func fetchReleases(from url: URL) async throws -> [Release] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    // MARK: - Selection (SelectLatestRelease)

    /// Pick the release an upgrade would go to, or throw `.noApplicableRelease`.
    ///
    /// Same rules as the daemon: newest first; a *minor* upgrade is preferred over
    /// a newer *major* (the major resurfaces once the minor is installed — this is
    /// what lets the app's major-consent gate present majors alone); prereleases
    /// are skipped unless opted in; a release only counts if it ships an asset
    /// named for this OS/arch (`syncthing-macos-<arch>-<tag>.`).
    static func selectLatestRelease(_ releases: [Release], current: String,
                                    upgradeToPreReleases: Bool, arch: String) throws -> Release {
        // Lowest version first, exactly like the Go original — the order is
        // load-bearing: `selected` is overwritten by every acceptable release
        // (so it ends on the newest), and the major-boundary check must see the
        // best pending minor before it reaches the major.
        let sorted = releases.sorted { compareVersions($0.tag, $1.tag) < .equal }

        var selected: Release?
        for release in sorted {
            if compareVersions(release.tag, current) == .majorNewer {
                // A new major. Fine — but if an acceptable *minor* upgrade is
                // already in hand, go with that first and revisit the major
                // once it's installed.
                if let selected, compareVersions(selected.tag, current) == .newer {
                    return selected
                }
            }

            if release.prerelease && !upgradeToPreReleases { continue }

            let expectedPrefixes = releaseNames(tag: release.tag, arch: arch)
            let matches = release.assets.contains { asset in
                let assetName = (asset.name as NSString).lastPathComponent
                return expectedPrefixes.contains { assetName.hasPrefix($0) }
            }
            if matches {
                selected = release
            }
        }

        guard let selected else { throw FeedError.noApplicableRelease }
        return selected
    }

    /// The asset-name prefixes that identify a macOS build of `tag` for `arch`
    /// (the daemon's `runtime.GOARCH`, e.g. "arm64" — read it from
    /// `/rest/system/version`). Matching on the full prefix (name + arch + tag +
    /// ".") mirrors the daemon's protection against malformed release data.
    private static func releaseNames(tag: String, arch: String) -> [String] {
        ["syncthing-macos-\(arch)-\(tag).", "syncthing-macosx-\(arch)-\(tag)."]
    }

    // MARK: - Version comparison (CompareVersions)

    /// How version `a` relates to version `b`.
    enum Relation: Int, Comparable {
        case majorOlder = -2, older = -1, equal = 0, newer = 1, majorNewer = 2
        static func < (lhs: Relation, rhs: Relation) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Syncthing's version ordering: dotted numerics compared piecewise (a
    /// difference in the first field is major); a longer equal-prefix version is
    /// newer; a prerelease is older than its release; prerelease fields compare
    /// numerically when numeric, lexically when not, with numeric < string.
    /// Special case: v0.x and v1.x are equivalent in majorness.
    static func compareVersions(_ a: String, _ b: String) -> Relation {
        let (arel, apre) = versionParts(a)
        let (brel, bpre) = versionParts(b)

        for i in 0..<min(arel.count, brel.count) {
            if arel[i] < brel[i] {
                if i == 0 {
                    return (arel[0] == 0 && brel[0] == 1) ? .older : .majorOlder
                }
                return .older
            }
            if arel[i] > brel[i] {
                if i == 0 {
                    return (arel[0] == 1 && brel[0] == 0) ? .newer : .majorNewer
                }
                return .newer
            }
        }

        // Longer version is newer, when the preceding parts are equal.
        if arel.count < brel.count { return .older }
        if arel.count > brel.count { return .newer }

        // Prerelease versions are older, if the versions are the same.
        if apre.isEmpty && !bpre.isEmpty { return .newer }
        if !apre.isEmpty && bpre.isEmpty { return .older }

        for i in 0..<min(apre.count, bpre.count) {
            switch (apre[i], bpre[i]) {
            case let (.number(av), .number(bv)):
                if av < bv { return .older }
                if av > bv { return .newer }
            case (.number, .text):
                return .older
            case (.text, .number):
                return .newer
            case let (.text(av), .text(bv)):
                if av < bv { return .older }
                if av > bv { return .newer }
            }
        }

        // If all else is equal, longer prerelease string is newer.
        if apre.count < bpre.count { return .older }
        if apre.count > bpre.count { return .newer }

        return .equal
    }

    /// One dot-separated field of a prerelease suffix.
    private enum PrereleaseField: Equatable {
        case number(Int)
        case text(String)
    }

    /// "v1.2.3-beta.2+meta" → ([1, 2, 3], [.text("beta"), .number(2)]).
    /// Non-numeric release fields parse as 0, as in the Go original (`Atoi`
    /// result used regardless of error).
    private static func versionParts(_ version: String) -> ([Int], [PrereleaseField]) {
        var v = Substring(version)
        if v.first == "v" || v.first == "V" { v = v.dropFirst() }
        let withoutBuild = v.split(separator: "+", maxSplits: 1,
                                   omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1,
                                       omittingEmptySubsequences: false)

        let release = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        var prerelease: [PrereleaseField] = []
        if parts.count > 1 {
            prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false)
                .map { Int($0).map(PrereleaseField.number) ?? .text(String($0)) }
        }
        return (release, prerelease)
    }
}
