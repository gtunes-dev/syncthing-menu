import Foundation
import Combine

/// The update status of one channel.
enum UpdateState: Equatable {
    /// Not checked (also the resting state when auto-check is off).
    case unknown
    /// A check is in progress.
    case checking
    /// Running the latest available version.
    case upToDate
    /// An update is available. `isMajor` is meaningful only on a channel that gates
    /// majors (Syncthing) — there, a major waits for explicit consent.
    case available(version: String, isMajor: Bool)
    /// An update is being applied.
    case installing

    var isInstalling: Bool { if case .installing = self { return true } else { return false } }
}

/// Thrown by a mechanism's `applyUpdate(userInitiated:)` when the user declined
/// the offered update (dismissed or skipped its consent UI). Not a failure: the
/// policy layer restores the prior `.available` state, so the update stays
/// offered and the Update button works again immediately.
struct UpdateDeclinedError: Error {}

/// Serializes installs across every channel: at most one update — the app or
/// Syncthing — is ever being applied at a time, so a Sparkle relaunch can never land
/// mid-daemon-upgrade (or vice versa). Main-thread confined like all update policy,
/// so a claim is a plain check — no locking. The guarantee covers our own automation
/// only: the user can still quit mid-install, which the process layer already
/// tolerates (`SyncthingProcess.isTerminating`, and Syncthing's own verify-then-swap
/// upgrade).
final class UpdateInstallCoordinator: ObservableObject {
    static let shared = UpdateInstallCoordinator()

    /// The channel currently applying an update, if any. While non-nil the Settings
    /// UI disables the idle card's Update button; when it returns to nil, channels
    /// re-evaluate a deferred auto-install.
    @Published private(set) var installingChannel: UpdateSource?

    /// Claim the exclusive right to install. False when another channel holds it —
    /// the caller should defer (stay `.available`), not queue.
    func claim(_ channel: UpdateSource) -> Bool {
        guard installingChannel == nil else { return false }
        installingChannel = channel
        return true
    }

    /// Release a claim. A no-op unless `channel` is the current holder.
    func release(_ channel: UpdateSource) {
        if installingChannel === channel { installingChannel = nil }
    }
}

/// One update channel. The base owns all update *policy* and publishes the state the
/// UI renders; a concrete channel subclasses it and supplies only its *mechanism* —
/// how to read the running version, check for an update, and apply one. Policy is
/// therefore identical across channels:
///
/// - While available and auto-check is on, the channel checks at launch and on a
///   timer; every completed check records `settings.lastChecked`.
/// - When auto-install is effective, a found update is applied immediately — except a
///   major update on a channel that gates majors, which waits for explicit consent.
/// - When auto-check is off the channel never checks on its own and surfaces nothing;
///   only `checkNow()` (the Check Now button) probes.
/// - Installs are serialized app-wide (`UpdateInstallCoordinator`): while one channel
///   installs, a found update on the other stays `.available` and re-evaluates for
///   auto-install once the install finishes.
///
/// Concurrency model: everything here is main-thread confined — state, timers, the
/// settings sinks, and the async tasks (`Task { @MainActor in … }`). What prevents
/// interleaving is not locks but single-flight state checked on main before each
/// operation starts (`checkInFlight`, `.installing`, the coordinator's claim).
class UpdateSource: ObservableObject {
    /// Display name for the settings card, e.g. "Syncthing Menu" or "Syncthing".
    let name: String

    /// The running/installed version, when known.
    @Published private(set) var currentVersion: String?

    /// The latest known update state.
    @Published private(set) var state: UpdateState = .unknown

    /// This channel's persisted settings (toggles + last-checked).
    let settings: UpdateChannelSettings

    /// Whether a major update waits for explicit consent instead of auto-installing.
    let gatesMajorUpdates: Bool

    /// Cross-channel install serialization; the Settings UI observes its
    /// `installingChannel` to disable the idle card's Update button.
    let coordinator: UpdateInstallCoordinator

    /// True while the channel can be checked (Syncthing Menu: from launch; Syncthing:
    /// while the daemon is running).
    private(set) var isAvailable = false

    private let pollInterval: TimeInterval

    /// Bumped whenever availability changes, so an in-flight async operation can
    /// detect it has been superseded and bail. (Checks themselves are serialized by
    /// `checkInFlight`, installs by the coordinator.)
    private var epoch = 0
    /// Guards against overlapping checks (e.g. a poll tick landing on an in-flight check).
    private var checkInFlight = false
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(name: String, settings: UpdateChannelSettings,
         pollInterval: TimeInterval, gatesMajorUpdates: Bool,
         coordinator: UpdateInstallCoordinator = .shared) {
        self.name = name
        self.settings = settings
        self.pollInterval = pollInterval
        self.gatesMajorUpdates = gatesMajorUpdates
        self.coordinator = coordinator

        // `.receive(on:)` defers past @Published's willSet emission so the handlers
        // observe the new toggle values.
        settings.$autoCheckEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.autoCheckChanged(to: enabled) }
            .store(in: &cancellables)
        settings.$autoInstallEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.autoInstallIfEligible() }
            .store(in: &cancellables)
        // When an install elsewhere finishes, re-evaluate a deferred auto-install here.
        coordinator.$installingChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] installing in
                if installing == nil { self?.autoInstallIfEligible() }
            }
            .store(in: &cancellables)
    }

    deinit { pollTimer?.invalidate() }

    // MARK: - Availability (raised by the subclass)

    /// The channel can now be checked. Reads the current version for the header and,
    /// when auto-check is on, checks immediately and begins polling.
    func makeAvailable() {
        isAvailable = true
        epoch &+= 1
        checkInFlight = false
        if settings.autoCheckEnabled {
            runCheck()
            startPolling()
        } else {
            // Surface the version without probing for updates.
            let token = epoch
            Task { @MainActor in
                let version = await self.fetchVersion()
                guard self.epoch == token else { return }
                self.currentVersion = version
            }
        }
    }

    /// The channel can no longer be checked. Stops polling and resets to unchecked.
    func makeUnavailable() {
        isAvailable = false
        epoch &+= 1
        checkInFlight = false
        stopPolling()
        currentVersion = nil
        state = .unknown
    }

    // MARK: - User actions

    /// Check now. A user action (Check Now button) or a poll tick — runs whenever the
    /// channel is available, regardless of the auto-check toggle.
    func checkNow() {
        guard isAvailable, !state.isInstalling else { return }
        runCheck()
    }

    /// Apply the available update — from the Update button or menu item
    /// (`userInitiated: true`, the default) or an eligible auto-install (`false`).
    /// The mechanism may present consent UI on the user-initiated path; a decline
    /// (`UpdateDeclinedError`) restores the prior `.available` state, so the update
    /// stays offered. Installs are serialized app-wide: if another channel is
    /// mid-install this defers (the state stays `.available`), and the coordinator's
    /// release re-evaluates it for auto-install. The claim is held through
    /// `didApplyUpdate()` — deliberately not through the daemon's post-upgrade
    /// re-root/reconnect, which is already safe against a quit or relaunch (a fresh
    /// spawn *is* the re-root).
    func installAvailable(userInitiated: Bool = true) {
        guard isAvailable, case .available = state else { return }
        guard coordinator.claim(self) else {
            Log.updates.log("\(self.name, privacy: .public): install deferred — another update is installing")
            return
        }
        let offered = state
        state = .installing
        let token = epoch
        Task { @MainActor in
            defer { self.coordinator.release(self) }
            do {
                try await self.applyUpdate(userInitiated: userInitiated)
            } catch is UpdateDeclinedError {
                if self.epoch == token { self.state = offered }
                return
            } catch {
                if self.epoch == token { self.state = .unknown }
                return
            }
            guard self.epoch == token else { return }
            self.didApplyUpdate()
        }
    }

    // MARK: - Policy

    /// Refresh the version, query availability, record the check, and auto-install when
    /// eligible.
    private func runCheck() {
        guard isAvailable, !checkInFlight, !state.isInstalling else { return }
        checkInFlight = true
        state = .checking
        let token = epoch
        Task { @MainActor in
            defer { self.checkInFlight = false }
            let version = await self.fetchVersion()
            let result: UpdateState
            do {
                result = try await self.checkForUpdate()
            } catch {
                if self.epoch == token { self.state = .unknown }
                return
            }
            guard self.epoch == token else { return }
            if let version { self.currentVersion = version }
            self.settings.lastChecked = Date()
            self.state = result
            if case let .available(_, isMajor) = result, self.shouldAutoInstall(isMajor: isMajor) {
                self.installAvailable(userInitiated: false)
            }
        }
    }

    private func shouldAutoInstall(isMajor: Bool) -> Bool {
        settings.autoInstallEffective && !(isMajor && gatesMajorUpdates)
    }

    private func autoCheckChanged(to enabled: Bool) {
        if enabled {
            guard isAvailable else { return }
            runCheck()
            startPolling()
        } else {
            // An opted-out channel surfaces nothing until the user checks manually.
            stopPolling()
            state = .unknown
        }
    }

    /// Apply the pending update if one is showing and auto-install applies to it.
    /// Run when the auto-install toggle changes and when a cross-channel install
    /// finishes (releasing a deferred install).
    private func autoInstallIfEligible() {
        guard case let .available(_, isMajor) = state, shouldAutoInstall(isMajor: isMajor) else { return }
        installAvailable(userInitiated: false)
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        // `.common` so a tick isn't deferred by runloop tracking (an open menu, a scroll).
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Mechanism (the subclass provides these)
    //
    // Contract: every mechanism call MUST complete — return or throw. The policy
    // layer's single-flight guards (`checkInFlight`, `.installing`, the coordinator's
    // claim) clear only on completion; a call that never resolves wedges the channel.
    // One sanctioned exception: an `applyUpdate` whose success path ends in app
    // termination (the app channel's install + relaunch) may stay pending until the
    // process dies — holding the coordinator claim to the end is exactly what keeps
    // the other channel from starting an install under a pending relaunch.
    // `@MainActor` makes the main confinement compiler-checked here (and matches
    // Sparkle's own isolation); the policy layer only calls these from main tasks.

    /// The running/installed version, for the card header.
    @MainActor func fetchVersion() async -> String? { nil }

    /// Query availability: `.upToDate`, or `.available(version:isMajor:)`.
    @MainActor func checkForUpdate() async throws -> UpdateState { .unknown }

    /// Apply the available update. Three outcomes: return (applied), throw
    /// `UpdateDeclinedError` (user declined consent UI — the update stays offered),
    /// or throw anything else (failure). `userInitiated` says whether a user action
    /// (Update button/menu item) started this; a mechanism may present consent UI
    /// only then.
    @MainActor func applyUpdate(userInitiated: Bool) async throws {}

    /// Hook run after `applyUpdate()` succeeds (e.g. Syncthing re-roots its daemon).
    @MainActor func didApplyUpdate() {}

    /// The release-notes page for a version of this channel, if derivable.
    func releaseNotesURL(for version: String) -> URL? { nil }
}
