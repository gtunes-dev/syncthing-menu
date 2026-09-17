import Foundation

/// The Syncthing update channel: an `UpdateSource` whose mechanism swaps the
/// managed daemon's binary while the daemon is stopped. It is available while
/// the daemon is running (given a session-verified API) and gates major updates
/// — Syncthing sequences a pending minor ahead of a major (`majorNewer` only
/// goes true once no minor is pending), so a major surfaces alone and waits for
/// explicit consent.
///
/// The install is a four-step sequence on the `ManagedDaemon`, each step with
/// its own definitive completion signal:
///
/// 1. **Stop** — `shutdown()`: resolves when the monitor is reaped and its
///    workers are gone (kernel truth, not an inference).
/// 2. **Swap** — `upgradeBinary(from:)`: Syncthing's own `upgrade --from`
///    subcommand, run with no daemon alive; resolves on its exit status. The
///    rename to `syncthing.old` happens under no live process, so no TCC
///    identity ever reads `.old` (the in-process upgrade's permission-prompt
///    and stuck-FDA incidents). Syncthing's download + release-signature
///    verification stays the supply-chain anchor; `--from` pins the asset the
///    check selected, so what was offered is what gets installed.
/// 3. **Start** — `start()`: resolves at the spawn (fresh PID, fresh TCC
///    disclaim, Developer-ID verification of the new binary) or throws.
/// 4. **Confirm** — the reconnected session's API reports a version other
///    than the pre-upgrade one (the daemon's own word, on a fresh connection);
///    then the previous binary is discarded.
///
/// Every failure path leaves a daemon running or `.failed` with a message —
/// never stopped silently. There is deliberately no rollback: Syncthing's own
/// upgrader has none, and a new binary that won't launch is a `.failed` daemon
/// with the reason, like any other launch failure. Two defenses keep a daemon-
/// mode switch from landing between steps 1 and 3: Settings disables the mode
/// picker while this channel is installing, and the step-1 stop's
/// `LaunchToken` is handed to every start here, so a stop that landed in
/// between (a mode switch through any other path) makes the start refuse with
/// `.superseded` instead of spawning a managed daemon the app no longer wants.
final class SyncthingUpdateSource: UpdateSource {
    private var api: SyncthingAPI?

    /// The managed daemon the mechanism sequences. Wired by the app delegate;
    /// nil (unwired) fails an install loudly rather than guessing.
    var daemon: ManagedDaemon?

    /// Whether the daemon is currently scanning or syncing (wired to the live
    /// monitor snapshot). The install waits briefly for idle before stopping
    /// the daemon: interrupting a pull is safe (Syncthing resumes it) but
    /// wasteful, and an idle daemon stops in a second. Nil (unwired, e.g.
    /// tests) skips the gate.
    var isDaemonBusy: (() -> Bool)?

    /// The release the last successful check selected, kept so the install
    /// pins exactly what the card offered — not whatever the feed says at
    /// click time. Cleared when the check finds nothing or the channel goes
    /// unavailable.
    private(set) var pendingUpgrade: PendingUpgrade?

    struct PendingUpgrade: Equatable {
        let tag: String
        let assetURL: URL
    }

    /// Upper bound (seconds) on waiting for the restarted daemon to report its
    /// version after the swap. The spawn already happened (or threw) and a
    /// daemon that dies ends the wait at once (`daemonFailed`), so this bounds
    /// only "alive but not answering" — which a major upgrade's first start
    /// legitimately is for as long as its database migration takes (minutes on
    /// a large database). Reporting such an install as failed would be a lie
    /// with consequences (suppressed version, `.old` never discarded), so the
    /// bound is generous; the menu reads Updating… throughout.
    var settleTimeout: TimeInterval = 30 * 60

    /// Upper bound (seconds) on the pre-stop wait for the daemon to go idle.
    /// Bounded so a long sync can't wedge the Update click; on expiry the
    /// install proceeds anyway (logged) — the idle gate is courtesy, not a
    /// correctness requirement.
    var quiesceTimeout: TimeInterval = 120

    /// The idle gate's and the settle wait's sleep between polls (0.5s).
    /// Injectable like every other polling type's (`fastSleep` in tests).
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    private let waitPollNanos: UInt64 = 500_000_000

    init(settings: UpdateChannelSettings) {
        super.init(name: "Syncthing", settings: settings,
                   pollInterval: 6 * 3600, gatesMajorUpdates: true)
    }

    override func releaseNotesURL(for version: String) -> URL? {
        ReleaseNotes.syncthing(version: version)
    }

    // MARK: - Daemon lifecycle

    /// Session hand-off: a non-nil API is a session-verified endpoint (the session
    /// owns readiness polling and the autoUpgradeIntervalH=0 invariant), so
    /// availability tracks it directly. Called only on real identity changes and
    /// process-level transitions — NOT on transient `.connecting` blips. During
    /// an install the policy layer defers the availability change until the
    /// install ends; the API itself is recorded at once, because the settle
    /// wait polls it — that is how the post-swap daemon's endpoint reaches the
    /// in-flight install.
    func sessionChanged(api: SyncthingAPI?) {
        self.api = api
        if api != nil {
            makeAvailable()
        } else {
            if !state.isInstalling { pendingUpgrade = nil }
            makeUnavailable()
        }
    }

    // MARK: - Mechanism

    /// The daemon's API reports Git-tag-style versions ("v2.1.1"). The "v" is
    /// tag orthography, not part of the version — strip it at this boundary so
    /// every UI surface shows bare semver, matching the app's own
    /// CFBundleShortVersionString convention. (`ReleaseNotes` re-normalizes
    /// when building tag URLs, so links are unaffected.)
    static func displayVersion(_ raw: String) -> String {
        String(raw.drop(while: { $0 == "v" || $0 == "V" }))
    }

    override func fetchVersion() async -> String? {
        (try? await api?.systemVersion()).map(Self.displayVersion)
    }

    /// Availability is determined client-side (`SyncthingReleases`): the daemon
    /// runs with `STNOUPGRADE=1` (no Web UI upgrade banner, no self-upgrades),
    /// which also disables its `GET /rest/system/upgrade`. We fetch the daemon's
    /// own `releasesURL` feed and apply its selection rules, then remember the
    /// selected asset for the install.
    override func checkForUpdate() async throws -> UpdateState {
        guard let api else { throw SyncthingAPI.APIError.badURL }
        let running = try await api.systemVersionInfo()
        let options = try await api.upgradeCheckOptions()
        guard let feedURL = URL(string: options.releasesURL) else {
            throw SyncthingAPI.APIError.badURL
        }
        let releases = try await SyncthingReleases.fetchReleases(from: feedURL)
        let latest = try SyncthingReleases.selectLatestRelease(
            releases, current: running.version,
            upgradeToPreReleases: options.upgradeToPreReleases, arch: running.arch)
        let isMajor: Bool
        switch SyncthingReleases.compareVersions(latest.tag, running.version) {
        case .majorNewer: isMajor = true
        case .newer: isMajor = false
        default:
            pendingUpgrade = nil
            return .upToDate
        }
        // Selection guarantees an asset for this arch; a nil here is a port bug.
        guard let asset = SyncthingReleases.upgradeAsset(of: latest, arch: running.arch) else {
            throw SyncthingReleases.FeedError.noApplicableRelease
        }
        // The install can only use a URL the release signature will accept
        // (one ending in the asset name). A feed without one is a check
        // failure — logged, retried — never an offer that can't be installed.
        guard let downloadURL = asset.downloadURL else {
            pendingUpgrade = nil
            throw SyncthingReleases.FeedError.assetNotInstallable(asset.name)
        }
        pendingUpgrade = PendingUpgrade(tag: latest.tag, assetURL: downloadURL)
        return .available(version: Self.displayVersion(latest.tag), isMajor: isMajor)
    }

    /// Why an install didn't end in a confirmed upgrade. Routed through the
    /// policy layer's failure path — state resets and the reason is logged.
    enum InstallError: LocalizedError, Equatable {
        case notWired
        case nothingPending
        case versionUnreadable
        case superseded
        case notConfirmed(after: TimeInterval)
        case daemonFailed

        var errorDescription: String? {
            switch self {
            case .notWired: "The Syncthing update mechanism isn't connected to a managed daemon"
            case .nothingPending: "No Syncthing release is pending installation"
            case .versionUnreadable: "Couldn't read the running version before upgrading"
            case .superseded: "Syncthing update superseded by quit"
            case let .notConfirmed(after): "Syncthing didn't report a new version within \(Int(after))s"
            case .daemonFailed: "Syncthing failed after the upgrade"
            }
        }
    }

    /// Same mechanism for user-initiated and automatic installs: there is no
    /// per-update consent UI on this channel (the click is the consent; release
    /// notes live on the card), so `userInitiated` is unused.
    override func applyUpdate(userInitiated: Bool) async throws {
        guard let daemon else { throw InstallError.notWired }
        guard let pending = pendingUpgrade else { throw InstallError.nothingPending }
        guard let api else { throw SyncthingAPI.APIError.badURL }
        // Raw-to-raw comparison, independent of the display normalization. The
        // pre-upgrade version MUST be readable: with `from` nil, the first
        // successful read in the settle wait would report any version as new.
        guard let from = try? await api.systemVersion() else {
            throw InstallError.versionUnreadable
        }

        await waitForIdle()

        // 1. Stop. The token binds both starts below to THIS stop.
        guard let token = await daemon.shutdown() else { throw InstallError.superseded }
        Log.updates.log("Syncthing upgrade: daemon stopped (running \(from, privacy: .public)); installing \(pending.tag, privacy: .public)")

        // 2. Swap. On any failure the previous binary is in place (the
        // daemon's contract), so the daemon restarts on it before we report.
        let swap: BinarySwap
        do {
            swap = try await daemon.upgradeBinary(from: pending.assetURL)
        } catch {
            Log.updates.error("Syncthing upgrade: swap failed — \(String(describing: error), privacy: .public); restarting the current version")
            try? await daemon.start(after: token)   // its own failure lands in the daemon's state + log
            throw error
        }

        // 3. Start the upgraded binary. A launch failure (the provenance check
        // is the realistic case) is the daemon's `.failed` state with its
        // reason, like any other launch failure: no rollback — Syncthing's own
        // upgrader has none either, and an automatic retry of a bad binary
        // would only loop.
        try await daemon.start(after: token)

        // 4. Confirm on the daemon's own word, then let go of the old binary.
        let version = try await waitForSettle(from: from, daemon: daemon)
        Log.updates.log("Syncthing upgrade settled: \(from, privacy: .public) → \(version, privacy: .public)")
        swap.discardPrevious()
        pendingUpgrade = nil
    }

    private func waitForIdle() async {
        let deadline = Date().addingTimeInterval(quiesceTimeout)
        while isDaemonBusy?() == true {
            if Date() >= deadline {
                Log.updates.log("Syncthing upgrade: daemon still busy after \(Int(self.quiesceTimeout))s — proceeding anyway")
                return
            }
            await sleepOnePoll()
        }
    }

    /// Poll the session's CURRENT API (`sessionChanged` hands over the
    /// post-swap endpoint; a config migration can move the port or rotate the
    /// key) until it reports a version other than `from`. Bails as soon as the
    /// daemon reports failure — a settle window spent waiting on a dead daemon
    /// would only delay the same answer. A timeout is a FAILURE: reporting
    /// success would let a persistently failing upgrade re-offer silently.
    private func waitForSettle(from: String, daemon: ManagedDaemon) async throws -> String {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline {
            guard daemon.isRunning else { throw InstallError.daemonFailed }
            if let version = try? await api?.systemVersion(), version != from {
                return version
            }
            await sleepOnePoll()
        }
        throw InstallError.notConfirmed(after: settleTimeout)
    }

    private func sleepOnePoll() async {
        await retrySleep(waitPollNanos)
    }
}
