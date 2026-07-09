import AppKit
import Foundation
import Sparkle

/// The Syncthing Menu update channel: an `UpdateSource` whose mechanism is Sparkle.
/// Available from launch, with no major gate. A check is a silent probe (no UI, no
/// download). Applying an update takes one of two paths:
///
/// - **Automatic** (auto-install policy): background download + stage, then
///   Sparkle's immediate-install handler — install + relaunch with no UI.
/// - **User-initiated** (Update button / menu item): Sparkle's standard update
///   dialog, shown front and center (a user-initiated session activates the app;
///   the behind-all-windows ordering is exclusive to scheduled sessions), with
///   release notes and Install / Remind Me Later / Skip. Declining restores the
///   card's "available" state; "Skip This Version" is deliberately soft (see
///   `clearSkippedVersions`).
///
/// Either install ends in a relaunch, which terminates the app, so the daemon is
/// stopped through `applicationWillTerminate` exactly as on any quit.
///
/// Set the `SPARKLE_TEST_FEED_URL` environment variable to point at a local appcast
/// for testing without editing Info.plist. Sparkle requires http(s) — a `file://`
/// URL is rejected at fetch time ("The download request URL must use http or
/// https"), so serve the feed over loopback (`python3 -m http.server`). Debug
/// builds keep the channel disabled unless that variable is set (see
/// `makeAvailable`).
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
        Self.clearSkippedVersions()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.pendingCheck = continuation
            controller.updater.checkForUpdateInformation()
        }
    }

    /// Apply the available update — see the class comment for the two paths.
    override func applyUpdate(userInitiated: Bool) async throws {
        guard !controller.updater.sessionInProgress else {
            // A background probe is mid-flight (sub-second window). On a click,
            // nothing has changed — report a decline so the card keeps offering
            // the update instead of falling back to "Not checked".
            if userInitiated { throw UpdateDeclinedError() }
            throw SparkleMechanismError.sessionAlreadyInProgress
        }
        Self.clearSkippedVersions()
        if userInitiated {
            try await applyUpdateInteractively()
        } else {
            try await applyUpdateSilently()
        }
    }

    /// Sparkle's standard dialog, front and center: release notes, then the user's
    /// call. Install proceeds through Sparkle's own UI and ends in relaunch — the
    /// continuation deliberately stays pending so the cross-channel install claim
    /// holds until termination (the mechanism contract's sanctioned exception).
    /// Remind Me Later / Skip / a failed session throws, restoring the card.
    @MainActor private func applyUpdateInteractively() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.pendingInteractive = continuation
            controller.updater.checkForUpdates()
        }
    }

    /// Download in the background, then install and relaunch with no UI. Sparkle
    /// routes a background-downloaded update through `willInstallUpdateOnQuit`; we
    /// take control and invoke its install handler immediately.
    ///
    /// Last resort: when Sparkle refuses to stage silently (`requiresUserAttention` —
    /// e.g. installing this copy would need admin authorization), the silent install
    /// fails, and we hand the parked session to Sparkle's own dialog brought to the
    /// front — never hidden behind windows. The user completes or declines the update
    /// there; either way the session ends and the channel is usable again. (The claim
    /// is released when this throws; the rare install-from-fallback runs unclaimed,
    /// accepted for a path that should never occur in production.)
    @MainActor private func applyUpdateSilently() async throws {
        do {
            let install: () -> Void = try await withCheckedThrowingContinuation { continuation in
                bridge.pendingInstall = continuation
                controller.updater.checkForUpdatesInBackground()
            }
            install()
        } catch SparkleMechanismError.requiresUserAttention {
            controller.updater.checkForUpdates()
            throw SparkleMechanismError.requiresUserAttention
        }
    }

    /// Sparkle persists "Skip This Version" and filters that version out of
    /// *background* sessions — which our probes are: one Skip would flip the card
    /// to "Up to date" until the next release. In this app the Settings card is
    /// the persistent, non-nagging reminder, so Skip means "not now": clear the
    /// record before every session, making Skip and Remind Me Later equivalent.
    /// (Keys from Sparkle's SUConstants.m.)
    private static func clearSkippedVersions() {
        for key in ["SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"] {
            UserDefaults.standard.removeObject(forKey: key)
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
    /// The silent (automatic) install path, resolved with the immediate-install handler.
    var pendingInstall: CheckedContinuation<() -> Void, Error>?
    /// The user-initiated dialog path. Resolved as `UpdateDeclinedError` when the user
    /// declines, as failure when the session errors — and deliberately left pending
    /// when the user chooses Install (the flow ends in relaunch; see `applyUpdate`).
    var pendingInteractive: CheckedContinuation<Void, Error>?
    /// The user chose Install in the dialog: an installer is now running and the app
    /// is on its way to relaunch, so a nil-error end of cycle must NOT resolve
    /// `pendingInteractive` (the claim holds until termination).
    private var interactiveInstallChosen = false

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride ?? Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    // A probe found an update. (Syncthing Menu has no major distinction.)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        resolveCheck(.success(.available(version: item.displayVersionString, isMajor: false)))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if pendingCheck != nil { resolveCheck(.success(.upToDate)) }
        resolveInstall(.failure(error))
        // The card offered a version the fresh appcast no longer has (e.g. a pulled
        // release). Fail the apply; the next check corrects the card.
        resolveInteractive(.failure(error))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if pendingCheck != nil { resolveCheck(.failure(error)) }
        resolveInstall(.failure(error))
        resolveInteractive(.failure(error))
    }

    // The user's verdict in the update dialog (user-initiated sessions, and the
    // silent path's needs-attention fallback — where the pending is already nil).
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .install:
            // Consent to install: Sparkle's UI carries it to relaunch. Leave the
            // continuation pending so the install claim holds until termination;
            // a failure from here on still resolves via the abort/cycle-end paths.
            interactiveInstallChosen = true
        case .skip, .dismiss:
            // Skip and Remind Me Later both mean "not now" here (the skip record
            // is cleared at each session start): the card keeps offering it.
            resolveInteractive(.failure(UpdateDeclinedError()))
        @unknown default:
            resolveInteractive(.failure(UpdateDeclinedError()))
        }
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
    // Exception: after an Install choice a nil-error end means the installer is
    // carrying the update to relaunch — leave the interactive pending (and with it
    // the install claim) in place for the process's remaining moments.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        let failure = error ?? SparkleMechanismError.endedWithoutVerdict
        resolveCheck(.failure(failure))
        resolveInstall(.failure(failure))
        if error != nil || !interactiveInstallChosen {
            resolveInteractive(.failure(failure))
        }
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

    // Two ways here: on a user-initiated dialog this fires as a courtesy notification
    // (`pendingInstall` is nil — no-op; `pendingInteractive` resolves via the user's
    // choice instead). On the SILENT path it means Sparkle decided the update needs
    // user interaction (can't stage silently) and would route it to its standard UI —
    // suppressed above, so it lands here: fail the pending install, and
    // `applyUpdateSilently()`'s catch hands the parked session to Sparkle's dialog in
    // front. In the silent-success path this fires, if at all, only after
    // `willInstallUpdateOnQuit` — the pending is nil then.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        resolveInstall(.failure(SparkleMechanismError.requiresUserAttention))
        hideAutomaticUpdatesCheckbox()
    }

    // Sparkle's update alert offers "Automatically download and install updates in
    // the future" whenever the app is automatic-updates capable (which the silent
    // path requires) — there is no sanctioned way to opt out. The checkbox binds
    // straight to the Sparkle-level SUAutomaticallyUpdate default our mechanism
    // owns: checking it enables nothing (our auto-install policy gates installs)
    // and unchecking it would silently degrade the silent path until relaunch.
    // Our Settings checkbox is the one control, so hide the row — the same view
    // Sparkle itself hides when automatic updates aren't allowed. The button is
    // identified by its xib value-binding (localization-proof); if a future
    // Sparkle restructures the alert this finds nothing and the checkbox simply
    // reappears — a cosmetic-only failure.
    private func hideAutomaticUpdatesCheckbox() {
        // The alert window finishes loading after this delegate returns.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let content = window.contentView,
                      let checkbox = Self.automaticUpdatesCheckbox(in: content) else { continue }
                checkbox.superview?.isHidden = true
            }
        }
    }

    private static func automaticUpdatesCheckbox(in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           let info = button.infoForBinding(.value),
           let keyPath = info[.observedKeyPath] as? String,
           keyPath.contains("automaticallyDownloadsUpdates") {
            return button
        }
        for subview in view.subviews {
            if let found = automaticUpdatesCheckbox(in: subview) { return found }
        }
        return nil
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

    private func resolveInteractive(_ result: Result<Void, Error>) {
        guard let continuation = pendingInteractive else { return }
        pendingInteractive = nil
        interactiveInstallChosen = false
        continuation.resume(with: result)
    }
}
