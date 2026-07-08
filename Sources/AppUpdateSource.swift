import Foundation
import Sparkle

/// The Syncthing Menu update channel: an `UpdateSource` whose mechanism is Sparkle.
/// Available from launch, with no major gate. A check is a silent probe (no UI, no
/// download); applying an update downloads it in the background and installs +
/// relaunches the app with no UI. The relaunch terminates the app, so the daemon is
/// stopped through `applicationWillTerminate` exactly as on any quit. If Sparkle
/// decides an update can't be staged silently, the install fails fast instead of
/// parking behind Sparkle UI (see the user-driver hook in `SparkleBridge`).
///
/// Set the `SPARKLE_TEST_FEED_URL` environment variable to point at a local appcast
/// (e.g. a `file://` URL) for testing without editing Info.plist. Debug builds keep
/// the channel disabled unless that variable is set (see `makeAvailable`).
final class AppUpdateSource: UpdateSource {
    private let bridge = SparkleBridge()
    private var controller: SPUStandardUpdaterController!
    private let feedURLOverride: String?

    init(settings: UpdateChannelSettings,
         feedURLOverride: String? = ProcessInfo.processInfo.environment["SPARKLE_TEST_FEED_URL"]) {
        self.feedURLOverride = feedURLOverride
        super.init(name: "Syncthing Menu", settings: settings,
                   pollInterval: 24 * 3600, gatesMajorUpdates: false)
        bridge.feedURLOverride = feedURLOverride
        // The bridge is also the standard user driver's delegate — not to drive UI
        // (there is none on this path) but to detect Sparkle deciding it NEEDS UI.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: bridge,
                                                  userDriverDelegate: bridge)
        // We drive cadence ourselves. Downloads happen in the background while running,
        // so applying an update is a local install + relaunch with no network at quit.
        // automaticallyDownloadsUpdates only sticks because Info.plist sets
        // SUAllowsAutomaticUpdates: with automaticallyChecksForUpdates off, Sparkle
        // otherwise derives its allows-automatic-updates gate from that setting and
        // silently ignores this setter (which is what sent the 0.1.3→0.1.4 update
        // through the interactive alert instead of the silent path).
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = true
        NSLog("[Updates] Sparkle config: allowsAutomaticUpdates=%d automaticallyDownloadsUpdates=%d",
              controller.updater.allowsAutomaticUpdates, controller.updater.automaticallyDownloadsUpdates)
    }

    /// Debug builds never fight the production appcast: a dev build always reads the
    /// released app as "newer" (local CFBundleVersion=1 vs CI's git-count) and, being
    /// ad-hoc signed, can't be silently updated anyway. The channel stays unavailable
    /// unless a test feed is explicitly supplied.
    override func makeAvailable() {
        #if DEBUG
        guard feedURLOverride != nil else {
            NSLog("[Updates] Syncthing Menu channel disabled in Debug builds (set SPARKLE_TEST_FEED_URL to enable)")
            return
        }
        #endif
        super.makeAvailable()
    }

    override func releaseNotesURL(for version: String) -> URL? {
        ReleaseNotes.app(version: version)
    }

    // MARK: - Mechanism

    override func fetchVersion() async -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Silent probe: discovers whether an update exists, with no download and no UI.
    override func checkForUpdate() async throws -> UpdateState {
        // Fail fast if a session is already running — `checkForUpdateInformation()`
        // silently does nothing in that state, which would leak the continuation.
        // Guard on `sessionInProgress`, not `canCheckForUpdates`: Sparkle re-enables
        // the latter while a session is parked showing an update (so a user-initiated
        // check can refocus it), which let a probe slip through on 2026-07-07.
        guard !controller.updater.sessionInProgress else {
            throw SparkleMechanismError.sessionAlreadyInProgress
        }
        return try await withCheckedThrowingContinuation { continuation in
            bridge.pendingCheck = continuation
            controller.updater.checkForUpdateInformation()
        }
    }

    /// Download in the background, then install and relaunch with no UI. Sparkle routes
    /// a background-downloaded update through `willInstallUpdateOnQuit`; we take control
    /// and invoke its install handler immediately.
    ///
    /// Last resort: when Sparkle refuses to stage silently (`requiresUserAttention` —
    /// e.g. installing this copy would need admin authorization), the silent install
    /// fails, and we hand the parked session to Sparkle's own dialog brought to the
    /// front — the Update click that got us here is the consent to show it. The user
    /// completes or cancels the update there; either way the session ends and the
    /// channel is usable again.
    override func applyUpdate() async throws {
        guard !controller.updater.sessionInProgress else {
            throw SparkleMechanismError.sessionAlreadyInProgress
        }
        do {
            let install: () -> Void = try await withCheckedThrowingContinuation { continuation in
                bridge.pendingInstall = continuation
                controller.updater.checkForUpdatesInBackground()
            }
            install()
        } catch SparkleMechanismError.requiresUserAttention {
            // The session is parked on the update whose alert we suppressed in
            // `standardUserDriverShouldHandleShowingScheduledUpdate`. A user-initiated
            // check is Sparkle's documented hand-off: it refocuses that pending update,
            // activating the app and presenting its dialog front and center.
            controller.updater.checkForUpdates()
            throw SparkleMechanismError.requiresUserAttention
        }
    }
}

/// Sparkle mechanism failures its delegate doesn't surface. Throwing them (rather
/// than waiting) keeps the mechanism contract — every call completes — so the policy
/// layer's single-flight guards can't wedge.
private enum SparkleMechanismError: Error {
    /// A session was already in progress, so a new check/install couldn't start.
    case sessionAlreadyInProgress
    /// An update cycle ended without any verdict callback firing.
    case endedWithoutVerdict
    /// Sparkle decided the update needs user interaction (it can't be staged
    /// silently — e.g. the installed app's code signing doesn't match the update's),
    /// so the no-UI install path can't proceed.
    case requiresUserAttention
}

/// NSObject bridge to Sparkle's `@objc` delegates, translating its callbacks into the
/// continuations `AppUpdateSource` awaits. `SPUUpdater`'s delegates run on the main
/// thread, where the continuations are fulfilled.
private final class SparkleBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var feedURLOverride: String?
    var pendingCheck: CheckedContinuation<UpdateState, Error>?
    var pendingInstall: CheckedContinuation<() -> Void, Error>?

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride ?? Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    // A probe found an update. (Syncthing Menu has no major distinction.)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        resolveCheck(.success(.available(version: item.displayVersionString, isMajor: false)))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if pendingCheck != nil { resolveCheck(.success(.upToDate)) }
        else { resolveInstall(.failure(error)) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if pendingCheck != nil { resolveCheck(.failure(error)) }
        else { resolveInstall(.failure(error)) }
    }

    // A background-downloaded update is staged and ready. Take control and hand the
    // immediate install + relaunch block to the waiting apply.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        resolveInstall(.success(immediateInstallHandler))
        return true
    }

    // Backstop: a cycle that ends without a verdict callback must still resolve
    // whatever is pending, or the channel wedges (its `checkInFlight` / `.installing`
    // guards never clear). On the normal paths the pendings are already nil here.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        let failure = error ?? SparkleMechanismError.endedWithoutVerdict
        resolveCheck(.failure(failure))
        resolveInstall(.failure(failure))
    }

    // Never let Sparkle present its own alert for a scheduled (background) update:
    // for a background app with a key window it deliberately orders that alert BEHIND
    // all windows (`orderBack:`), leaving an orphaned dialog lurking there — observed
    // behind the Settings window on the 0.1.3→0.1.4 update. Returning false makes
    // Sparkle notify `standardUserDriverWillHandleShowingUpdate` instead, below.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    // Sparkle decided the update needs user interaction (it can't stage silently) and
    // would route it to its standard UI — suppressed above, so it lands here instead.
    // Fail the pending install: the silent path is over, and `applyUpdate()`'s catch
    // hands the parked session to Sparkle's dialog in front. A check landing while
    // that session lingers fails fast via the `sessionInProgress` guard. In the
    // silent-success path this fires, if at all, only after `willInstallUpdateOnQuit`
    // — the pending is nil then.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        resolveInstall(.failure(SparkleMechanismError.requiresUserAttention))
    }

    private func resolveCheck(_ result: Result<UpdateState, Error>) {
        guard let continuation = pendingCheck else { return }
        pendingCheck = nil
        continuation.resume(with: result)
    }

    private func resolveInstall(_ result: Result<() -> Void, Error>) {
        guard let continuation = pendingInstall else { return }
        pendingInstall = nil
        continuation.resume(with: result)
    }
}
