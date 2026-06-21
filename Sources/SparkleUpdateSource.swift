import Foundation
import Sparkle

/// App self-update via Sparkle, exposed through the shared `UpdateSource` surface
/// so it drops in for the App `MockUpdateSource`.
///
/// Behavior:
/// - Silent background checks (`checkForUpdateInformation()`, on launch + a timer)
///   set `state` for the menu-bar badge and the Settings card — nothing pops up
///   unprompted.
/// - User-initiated `checkNow()` / `installAvailable()` call `checkForUpdates()`,
///   which shows Sparkle's standard window (release notes, download, install,
///   relaunch). We don't reimplement that flow.
/// - Sparkle's own scheduled checks are disabled; we drive cadence ourselves, for
///   consistency with `SyncthingUpdateSource` and to keep the UI unintrusive.
///
/// Set the `SPARKLE_TEST_FEED_URL` environment variable to point at a local
/// appcast (e.g. a `file://` URL) for testing without touching Info.plist.
final class SparkleUpdateSource: UpdateSource {
    private let bridge = SparkleUpdaterDelegate()
    private var controller: SPUStandardUpdaterController!
    private var pollTimer: Timer?

    /// How often to silently re-check for the badge.
    private let pollInterval: TimeInterval = 24 * 60 * 60

    init(feedURLOverride: String? = ProcessInfo.processInfo.environment["SPARKLE_TEST_FEED_URL"]) {
        super.init(name: "App")
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        bridge.feedURLOverride = feedURLOverride
        bridge.onFoundUpdate = { [weak self] item in self?.handleFound(item) }
        bridge.onNoUpdate = { [weak self] in self?.setState(.upToDate) }
        bridge.onCycleFinished = { [weak self] in self?.resetIfStuckChecking() }
        bridge.onError = { [weak self] error in
            NSLog("[Sparkle] update check failed: \(error.localizedDescription)")
            self?.resetIfStuckChecking()
        }

        // Start the updater. We manage cadence ourselves, so disable Sparkle's timer.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: bridge,
                                                  userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false

        // Initial silent probe (next runloop, once the updater has settled) + a
        // recurring badge refresh.
        DispatchQueue.main.async { [weak self] in self?.refreshSilently() }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refreshSilently()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit { pollTimer?.invalidate() }

    // MARK: - UpdateSource

    /// User asked to check. Show Sparkle's standard flow (also gives the "you're up
    /// to date" confirmation, which a silent check wouldn't).
    override func checkNow() {
        setState(.checking)
        controller.updater.checkForUpdates()
    }

    /// User asked to install the available update. Sparkle's window owns the
    /// download / install / relaunch UX.
    override func installAvailable() {
        controller.updater.checkForUpdates()
    }

    // MARK: - Internals

    /// Silent check used to drive the badge — shows no UI unless an error occurs.
    private func refreshSilently() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
    }

    private func handleFound(_ item: SUAppcastItem) {
        let version = item.displayVersionString
        setState(.available(version: version, isMajor: item.isMajorUpgrade))
    }

    /// If a check ended (e.g. user cancelled) without resolving, don't leave the
    /// card spinning on `.checking`.
    private func resetIfStuckChecking() {
        if case .checking = state { setState(.upToDate) }
    }

    private func setState(_ newState: UpdateState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { [weak self] in self?.state = newState }
        }
    }
}

/// NSObject bridge implementing Sparkle's `@objc` delegate protocol, forwarding to
/// closures on `SparkleUpdateSource` (which isn't an NSObject/`@objc` class and so
/// can't conform directly).
private final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var feedURLOverride: String?
    var onFoundUpdate: ((SUAppcastItem) -> Void)?
    var onNoUpdate: (() -> Void)?
    var onCycleFinished: (() -> Void)?
    var onError: ((Error) -> Void)?

    func feedURLString(for updater: SPUUpdater) -> String? {
        let url = feedURLOverride ?? Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        NSLog("[Sparkle] using feed URL: \(url ?? "<nil>")")
        return url
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        onError?(error)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onFoundUpdate?(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        onNoUpdate?()
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        onCycleFinished?()
    }
}
