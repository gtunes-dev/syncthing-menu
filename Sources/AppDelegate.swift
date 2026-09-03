import AppKit
import Combine
import os

/// Application lifecycle owner. Owns the menu-bar controller, the settings and about
/// windows, the Syncthing subprocess supervisor, and the two update channels.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?
    private var activityWindowController: ActivityWindowController?
    private let loginItem = LoginItemController()
    /// Folders blocked on permissions, shared with the Settings UI (the FDA
    /// section's alert state). Fed from the monitor's snapshot below.
    private let folderHealth = FolderHealth()
    private let releaseUpdater = ReleaseUpdater()
    private let syncthingProcess = SyncthingProcess()
    /// The session layer: turns "an endpoint should exist" + reachability into a
    /// verified `SyncthingAPI` (or nothing). All REST consumers hang off this.
    /// Rebuilt on every daemon-mode activation — managed sessions discover via
    /// the process's config.xml and enforce the no-self-upgrade invariant;
    /// self-managed sessions discover via the user-entered endpoint and
    /// deliberately enforce nothing on a daemon we don't own.
    private var daemonSession: DaemonSession?
    /// Discovery source for self-managed mode: the Settings-entered address/key.
    private lazy var selfManagedEndpoints =
        SelfManagedEndpointSource(settings: Settings.shared.daemon)
    /// The mode currently wired (set by `activate(mode:)` — reading the setting
    /// directly would be ambiguous mid-transition).
    private var activeMode: DaemonMode = .managed
    /// Bumped per activation so a mode switch supersedes the previous mode's
    /// in-flight async work (e.g. the shutdown-then-launch chain).
    private var modeGeneration = 0
    /// The latest probe verdict while self-managed and disconnected.
    private var lastConnectionIssue: SyncthingStatusModel.SelfManagedIssue = .connecting
    /// The API the consumers were last handed — session republishes after a blip
    /// recovery carry the same identity, and only real changes propagate.
    private var lastPublishedAPI: SyncthingAPI?
    /// Live daemon-state feed (pause/sync activity) over the events API — the
    /// single source of truth for daemon-side state while it runs.
    private let syncthingMonitor = SyncthingMonitor()
    /// Per-file change feed for the Activity window. Polls only while that
    /// window is visible.
    private let activityFeed = ActivityFeed()
    /// The canonical status presentation model — the menu-bar controller and
    /// the Activity window both render from it. Recomputed from the process
    /// state + monitor snapshot (`pushStatus`).
    private let syncthingStatus = SyncthingStatusModel()
    private var lastDaemonState: SyncthingProcess.State = .stopped
    private var lastMonitorSnapshot = SyncthingMonitor.Snapshot()
    private var cancellables = Set<AnyCancellable>()

    // Update channels behind the shared `UpdateSource` policy engine: the app via
    // Sparkle, Syncthing via its REST API.
    private let appUpdateSource = AppUpdateSource(settings: Settings.shared.app)
    private let syncthingUpdateSource = SyncthingUpdateSource(settings: Settings.shared.syncthing)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under the unit-test runner the app is only a test host: skip real startup
        // (status item, Sparkle, daemon bootstrap) — tests build their own fixtures.
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            return
        }

        let settingsController = SettingsWindowController(
            settings: .shared,
            appSource: appUpdateSource,
            syncthingSource: syncthingUpdateSource,
            loginItem: loginItem,
            folderHealth: folderHealth,
            status: syncthingStatus
        )
        settingsWindowController = settingsController

        let aboutController = AboutWindowController(
            // Managed: the update channel owns the version. Self-managed: that
            // channel is off; the status model carries the connected version.
            syncthingVersion: { [weak self] in
                self?.syncthingUpdateSource.currentVersion
                    ?? self?.syncthingStatus.selfManagedDaemonVersion
            }
        )
        aboutWindowController = aboutController

        let activityController = ActivityWindowController(feed: activityFeed,
                                                          status: syncthingStatus)
        activityController.onVisibilityChange = { [weak self] visible in
            self?.activityFeed.setWindowVisible(visible)
        }
        activityWindowController = activityController

        let controller = StatusItemController(
            status: syncthingStatus,
            onOpenSettings: { settingsController.show() },
            onAbout: { aboutController.show() }
        )
        controller.onOpenActivity = { reset in activityController.show(reset: reset) }
        controller.onMenuWillOpen = { [weak self] in self?.refreshFolders() }
        controller.onStartSyncthing = { [weak self] in self?.launchDaemon() }
        controller.onRescanAll = { [weak self] in self?.rescanAll() }
        controller.onPauseToggle = { [weak self] pause in self?.setAllDevicesPaused(pause) }
        controller.onUpdateApp = { [weak self] in self?.appUpdateSource.installAvailable() }
        controller.onUpdateSyncthing = { [weak self] in self?.syncthingUpdateSource.installAvailable() }
        statusItemController = controller

        // Reflect the managed daemon's live state in the status model (the menu
        // renders from it); the session turns lifecycle into a verified endpoint
        // for every REST consumer (supervision model: Process → Session →
        // consumers, design.md § Process & session supervision). The launch-time
        // GUI URL rides along; the session's verified URL supersedes it below.
        // In self-managed mode the process only ever transitions toward stopped
        // (the mode-switch shutdown) — those transitions drive nothing.
        syncthingProcess.onStateChange = { [weak self] state in
            guard let self, self.activeMode == .managed else { return }
            if case let .running(guiURL) = state {
                self.statusItemController?.update(webUIURL: guiURL)
            } else {
                self.statusItemController?.update(webUIURL: nil)
            }
            self.lastDaemonState = state
            self.pushStatus()
            self.daemonSession?.processStateChanged(state)
        }

        // The monitor doubles as the session's health probe: persistent long-poll
        // failure means the endpoint moved or died — let the session reconcile.
        // The dead stream also means the last snapshot's ACTIVITY is stale (a
        // wedged worker looks like this; so does a slow worker restart), so drop
        // it to idle rather than freeze the icon mid-Syncing indefinitely — no
        // other mechanism corrects it while the session sits in re-verify.
        // Race-safe by construction: the reconnect's reseed republishes truth
        // (promptly on a healthy endpoint; bounded by the session's retry
        // backoff while it stays unreachable — and while unreachable, activity
        // is genuinely unknown), display smoothing absorbs the dip, and
        // re-escalation is immediate. Pause and permission-error state are
        // stickier facts — kept until a real disconnect.
        syncthingMonitor.onEndpointSuspect = { [weak self] in
            guard let self else { return }
            self.lastMonitorSnapshot.activity = .idle
            self.pushStatus()
            self.daemonSession?.endpointSuspect()
        }

        // The monitor's snapshot feeds the status model (which drives the
        // icon's Paused/Syncing/attention marks, the status line, and the
        // Pause⇄Resume toggle label) plus the FDA section's alert state in
        // Settings.
        syncthingMonitor.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.folderHealth.permissionErrorFolders = snapshot.permissionErrorFolders
            self.lastMonitorSnapshot = snapshot
            self.pushStatus()
        }

        // After an upgrade settles, re-root the daemon supervisor: a fresh spawn
        // (new PID, fresh disclaim, canonical binary) ends the swap's TCC
        // exposure — see SyncthingUpdateSource.onUpgradeApplied for the full
        // story. The idle gate feeds the mechanism live activity so the POST
        // lands on a quiet daemon (both observed `syncthing.old` permission
        // incidents fired mid-scan).
        syncthingUpdateSource.onUpgradeApplied = { [weak self] in
            self?.syncthingProcess.restart()
        }
        syncthingUpdateSource.isDaemonBusy = { [weak self] in
            guard let self else { return false }
            return self.lastMonitorSnapshot.activity != .idle
        }

        // Surface pending updates in the menu (a direct action item per channel)
        // and on the menu-bar icon (one arrow for either; the tooltip names
        // versions). While one channel installs, the other's item is disabled —
        // installs are serialized app-wide, matching the Settings cards.
        Publishers.CombineLatest3(appUpdateSource.$state, syncthingUpdateSource.$state,
                                  UpdateInstallCoordinator.shared.$installingChannel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appState, syncState, installing in
                let idle = installing == nil
                self?.statusItemController?.update(
                    appUpdate: Self.pendingUpdate(appState, enabled: idle),
                    syncthingUpdate: Self.pendingUpdate(syncState, enabled: idle))
                // The menu's status line says Updating… for the whole install
                // window (quiesce → swap → re-root) instead of the phase churn.
                self?.syncthingStatus.update(
                    updatingSyncthing: installing != nil
                        && installing === self?.syncthingUpdateSource)
            }
            .store(in: &cancellables)

        // The app update channel is available from launch, independent of the daemon.
        // (Debug builds keep it off unless SPARKLE_TEST_FEED_URL is set.)
        appUpdateSource.makeAvailable()

        // Mode changes from Settings re-wire the daemon side live; the
        // self-managed connection fields re-arm discovery as the user edits
        // (debounced past the keystrokes; the session re-reads the fields on
        // every attempt, so a bump just makes the retry immediate).
        Settings.shared.daemon.$mode
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.activate(mode: mode) }
            .store(in: &cancellables)
        Settings.shared.daemon.connectionFieldEdited
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.activeMode == .selfManaged else { return }
                self.lastConnectionIssue = .connecting
                self.daemonSession?.setEndpointExpected(true)
                self.pushStatus()
            }
            .store(in: &cancellables)

        activate(mode: Settings.shared.daemon.mode)
    }

    // MARK: - Daemon mode

    /// Wire the daemon side for `mode` and bring it up. Called at launch and on
    /// every mode change. The previous session is torn down first (one clean
    /// disconnect reaches every consumer), then the managed daemon is stopped
    /// or started as the mode requires.
    @MainActor private func activate(mode: DaemonMode) {
        modeGeneration += 1
        let token = modeGeneration
        activeMode = mode
        Log.app.log("daemon mode: \(mode.rawValue, privacy: .public)")

        if let old = daemonSession {
            old.setEndpointExpected(false)   // fires .unavailable → consumer cleanup
            old.onChange = nil
            old.onProbeFailure = nil
        }
        syncthingStatus.update(selfManagedDaemonVersion: nil)
        daemonSession = makeSession(mode: mode)

        switch mode {
        case .managed:
            // Refresh from the process's real state, then push: while
            // self-managed was active the state handler was gated, so
            // `lastDaemonState` is stale (typically a frozen `.running`) —
            // without this push the menu would claim Running through the
            // whole bootstrap window.
            lastDaemonState = syncthingProcess.state
            pushStatus()
            // `shutdown` completes immediately when nothing is running (the
            // normal launch path); after a fast self-managed → managed flip it
            // waits out the reap so the fresh launch can't race the old spawn.
            syncthingProcess.shutdown { [weak self] in
                guard let self, self.modeGeneration == token else { return }
                self.launchDaemon()
            }
        case .selfManaged:
            syncthingProcess.shutdown()
            lastConnectionIssue = .connecting
            daemonSession?.setEndpointExpected(true)
            pushStatus()
        }
    }

    @MainActor private func makeSession(mode: DaemonMode) -> DaemonSession {
        let session: DaemonSession
        switch mode {
        case .managed:
            session = DaemonSession(endpoints: syncthingProcess)
        case .selfManaged:
            session = DaemonSession(endpoints: selfManagedEndpoints,
                                    enforcesNoSelfUpgrade: false)
            session.onProbeFailure = { [weak self] failure in
                guard let self, self.activeMode == .selfManaged else { return }
                let issue: SyncthingStatusModel.SelfManagedIssue =
                    failure == .apiKeyRejected ? .keyRejected : .unreachable
                if issue != self.lastConnectionIssue {
                    self.lastConnectionIssue = issue
                    self.pushStatus()
                }
            }
        }
        session.onChange = { [weak self] state in self?.sessionChanged(state) }
        return session
    }

    @MainActor private func sessionChanged(_ sessionState: DaemonSession.State) {
        switch sessionState {
        case let .connected(api):
            // The monitor reconnects on EVERY publish (its poll task ended if
            // it escalated; reseeding is cheap). The update source only sees
            // real identity changes, so a blip recovery on the same endpoint
            // doesn't reset an in-flight install or re-trigger checks.
            syncthingMonitor.connect(api: api)
            activityFeed.connect(api: api)
            if api != lastPublishedAPI {
                lastPublishedAPI = api
                if activeMode == .managed {
                    syncthingUpdateSource.sessionChanged(api: api)
                }
                statusItemController?.update(webUIURL: api.baseURL.absoluteString)
            }
            if activeMode == .selfManaged {
                lastConnectionIssue = .connecting   // reset for the next disconnect
                fetchSelfManagedVersion(api)
                pushStatus()
            }
            refreshFolders()
        case .unavailable:
            lastPublishedAPI = nil
            syncthingMonitor.disconnect()
            activityFeed.disconnect()
            syncthingUpdateSource.sessionChanged(api: nil)
            statusItemController?.update(folders: [])
            statusItemController?.update(webUIURL: nil)
            // The monitor's last snapshot dies with the daemon.
            folderHealth.permissionErrorFolders = []
            lastMonitorSnapshot = .init()
            syncthingStatus.update(selfManagedDaemonVersion: nil)
            pushStatus()
        case .connecting:
            // Transient (startup discovery or post-suspicion re-verify):
            // consumers keep what they have until it resolves. Self-managed
            // renders the transition — its "Connecting…" is a user-facing state.
            if activeMode == .selfManaged { pushStatus() }
        }
    }

    /// Surface the self-managed daemon's version (Settings header, About).
    private func fetchSelfManagedVersion(_ api: SyncthingAPI) {
        Task { @MainActor in
            guard let raw = try? await api.systemVersion(),
                  self.activeMode == .selfManaged else { return }
            self.syncthingStatus.update(
                selfManagedDaemonVersion: SyncthingUpdateSource.displayVersion(raw))
        }
    }

    /// Bootstrap the binary (download + verify if needed), then launch the
    /// managed daemon. Also the menu's "Start Syncthing" recovery path after a
    /// failure — `SyncthingProcess.start()` no-ops if the daemon is already up.
    /// Managed mode only: self-managed never downloads or spawns anything (the
    /// menu hides Start there; this guard covers stragglers like a bootstrap
    /// completing after a mode switch).
    private func launchDaemon() {
        guard activeMode == .managed else { return }
        Task { @MainActor in
            do {
                let url = try await releaseUpdater.bootstrapIfNeeded()
                Log.app.log("Syncthing binary ready at \(url.path, privacy: .public)")
                guard self.activeMode == .managed else { return }
                self.syncthingProcess.start()
            } catch {
                Log.app.error("Syncthing bootstrap failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncthingProcess.stop()
    }

    private static func pendingUpdate(_ state: UpdateState,
                                      enabled: Bool) -> StatusItemController.PendingUpdate? {
        guard case let .available(version, isMajor) = state else { return nil }
        return .init(version: version, isMajor: isMajor, enabled: enabled)
    }

    /// Recompute the shared global-status phase. Managed mode derives it from
    /// the process state + monitor snapshot; self-managed mode from the session
    /// (there is no process) — connected renders as the same `.running` phase,
    /// so the whole activity/paused/attention grammar applies in both modes.
    private func pushStatus() {
        let phase: SyncthingStatusModel.Phase
        switch activeMode {
        case .managed:
            switch lastDaemonState {
            case .stopped: phase = .notRunning
            case .starting: phase = .starting
            case .running:
                phase = runningPhase()
            case let .failed(message): phase = .failed(message)
            }
        case .selfManaged:
            if case .connected = daemonSession?.state {
                phase = runningPhase()
            } else if !selfManagedEndpoints.isConfigured {
                phase = .selfManaged(.notConfigured)
            } else {
                phase = .selfManaged(lastConnectionIssue)
            }
        }
        syncthingStatus.update(phase)
    }

    private func runningPhase() -> SyncthingStatusModel.Phase {
        .running(activity: lastMonitorSnapshot.activity,
                 paused: lastMonitorSnapshot.allDevicesPaused,
                 attention: !lastMonitorSnapshot.permissionErrorFolders.isEmpty)
    }

    /// A REST client for the running daemon, or nil when it isn't reachable.
    private var currentAPI: SyncthingAPI? { daemonSession?.api }

    /// Fetch the daemon's configured folders and push them to the menu. Leaves the
    /// current list untouched on a transient failure; clears it when the daemon
    /// isn't reachable.
    private func refreshFolders() {
        guard let api = currentAPI else {
            statusItemController?.update(folders: [])
            return
        }
        Task { @MainActor in
            guard let folders = try? await api.folders() else { return }
            self.statusItemController?.update(folders: folders.map {
                StatusItemController.FolderEntry(name: $0.label.isEmpty ? $0.id : $0.label,
                                                 path: $0.path)
            })
        }
    }

    private func rescanAll() {
        guard let api = currentAPI else { return }
        Task {
            do { try await api.rescanAll() }
            catch { Log.app.error("Rescan all failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Fire the pause/resume call; the resulting state comes back through the
    /// monitor's event stream (within milliseconds), so there is no optimistic
    /// local flip — one source of truth.
    private func setAllDevicesPaused(_ pause: Bool) {
        guard let api = currentAPI else { return }
        Task {
            do {
                if pause {
                    try await api.pauseAllDevices()
                } else {
                    try await api.resumeAllDevices()
                }
            } catch {
                Log.app.error("\(pause ? "Pause" : "Resume", privacy: .public) all devices failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

}
