import Foundation

/// Global Syncthing status as one observable value — the canonical
/// presentation model every status surface renders from: the menu-bar icon,
/// the menu's status row and tooltip (`StatusItemController`), and the
/// Activity window's subtitle and toolbar. Fed by `AppDelegate` from the
/// process-state push and the monitor's snapshot, so every surface tells the
/// same story in the same words.
///
/// `phase` is the truth; `display` is what surfaces render. Between them sits
/// the activity smoothing: real sync/scan episodes are often sub-second (and
/// event batching can collapse them entirely), so a truthful instant-render
/// icon flashes imperceptibly or not at all. Display therefore **escalates
/// immediately** (idle → scanning → syncing — never delay showing the more
/// consequential state) but **de-escalates lazily**: a level stays visible at
/// least `minimumVisibility`, and only drops after the lower truth has held
/// for `dropDebounce` — so folder-by-folder episodes read as one continuous
/// state, not flicker. The stretch is bounded and only ever overstates
/// *recent* activity; the states that carry obligations (paused, attention,
/// failed, not running) bypass smoothing entirely and render immediately —
/// they must never lag or be overstated.
///
/// Main thread only (every publisher feeds UI).
final class SyncthingStatusModel: ObservableObject {
    enum Phase: Equatable {
        case notRunning
        case starting
        case running(activity: SyncActivity, paused: Bool, attention: Bool)
        case failed(String)
        /// Self-managed mode while not connected. Once connected the phase is
        /// the same `.running` as managed mode — the monitor feeds the same
        /// activity truth either way, so the whole icon/status grammar applies.
        case selfManaged(SelfManagedIssue)
    }

    /// Why a self-managed connection isn't up. There is no failure-shaped
    /// terminal state here: the session polls forever, so each of these is a
    /// live condition that clears by itself once its cause does.
    enum SelfManagedIssue: Equatable {
        /// Address or API key not entered yet.
        case notConfigured
        /// Probing, no verdict yet (mode just activated or fields just edited).
        case connecting
        /// Probes are failing at the connection level — the daemon isn't
        /// answering at the configured address.
        case unreachable
        /// The daemon answered 401/403: a wrong or rotated API key.
        case keyRejected
    }

    /// The phase flattened through THE priority chain — attention > paused >
    /// syncing > scanning > running — resolved here and nowhere else. Cases
    /// are ordered by that priority. Surfaces map this value 1:1 to their
    /// medium (text, dot color, icon); none of them re-derive precedence.
    enum DisplayState: Equatable {
        case notRunning
        case starting
        case failed(String)
        /// Self-managed, fields not filled in yet.
        case notConfigured
        /// Self-managed, probing for the daemon.
        case connecting
        /// Self-managed, the daemon isn't answering.
        case unreachable
        /// Self-managed, the daemon rejected the API key — needs the user.
        case keyRejected
        /// A folder Syncthing can't access (permission error) — needs the user.
        case attention
        case paused
        case syncing
        case scanning
        case running
    }

    /// Once shown, an activity level stays visible at least this long.
    static let minimumVisibility: TimeInterval = 3.0
    /// A drop additionally waits for the lower truth to hold this long, so a
    /// gap between back-to-back episodes doesn't flicker through idle.
    static let dropDebounce: TimeInterval = 1.5

    /// Truth, straight from the process push + monitor snapshot.
    @Published private(set) var phase: Phase = .notRunning

    /// The self-managed daemon's version (display-normalized, bare semver)
    /// while connected; nil otherwise. In managed mode the update channel owns
    /// this fact — in self-managed mode that channel is off, so the Settings
    /// card header and About read it from here instead.
    @Published private(set) var selfManagedDaemonVersion: String?
    /// What surfaces render: `phase` through the priority chain, with the
    /// activity ladder smoothed (see the class doc).
    @Published private(set) var display: DisplayState = .notRunning

    /// Injectable clock (the monitor's seam pattern): tests drive the
    /// smoothing windows without real time passing.
    var now: () -> Date = Date.init

    /// The smoothed ladder state, non-nil only while `phase` exposes a
    /// smoothable activity (running, not paused, no attention).
    private struct ShownActivity {
        var activity: SyncActivity
        /// When this level became the shown one (minimum-visibility anchor).
        var since: Date
        /// When truth went (and stayed) below the shown level; nil = no drop
        /// pending (debounce anchor).
        var belowSince: Date?
    }

    private var shown: ShownActivity?
    private var dropTimer: Timer?

    deinit {
        dropTimer?.invalidate()
    }

    func update(_ new: Phase) {
        guard new != phase else { return }
        phase = new
        resmooth()
    }

    func update(selfManagedDaemonVersion version: String?) {
        guard version != selfManagedDaemonVersion else { return }
        selfManagedDaemonVersion = version
    }

    /// Re-run the smoothing rules after a truth change.
    private func resmooth() {
        guard let truth = smoothableActivity else {
            // Paused/attention/failed/stopped override the ladder and render
            // immediately — and no held activity survives them: when the
            // override clears, display restarts from the then-current truth.
            shown = nil
            dropTimer?.invalidate()
            refreshDisplay()
            return
        }
        let time = now()
        if var state = shown {
            if truth >= state.activity {
                if truth > state.activity {
                    // Escalation is immediate.
                    state.activity = truth
                    state.since = time
                }
                // Truth is back at (or above) the shown level — cancel any
                // pending drop; the display was continuously right.
                state.belowSince = nil
                dropTimer?.invalidate()
            } else {
                // Truth moving BETWEEN lower levels keeps the original anchor:
                // the debounce measures time below the shown level, not time
                // at one particular lower level.
                let below = state.belowSince ?? time
                state.belowSince = below
                scheduleDrop(at: max(state.since + Self.minimumVisibility,
                                     below + Self.dropDebounce))
            }
            shown = state
        } else {
            shown = ShownActivity(activity: truth, since: time, belowSince: nil)
        }
        refreshDisplay()
    }

    /// Apply a due de-escalation: drop the shown level to the current truth
    /// (not one step — the intermediate levels were never shown) and give the
    /// new level its own minimum-visibility window. The production timer
    /// lands here; internal so tests can drive it with the injected clock.
    func applyPendingDrop() {
        guard var state = shown, let truth = smoothableActivity,
              let below = state.belowSince, truth < state.activity else { return }
        let due = max(state.since + Self.minimumVisibility,
                      below + Self.dropDebounce)
        guard now() >= due else {
            scheduleDrop(at: due)
            return
        }
        state.activity = truth
        state.since = now()
        state.belowSince = nil
        shown = state
        refreshDisplay()
    }

    /// The activity subject to smoothing — nil whenever a higher-priority
    /// state owns the display.
    private var smoothableActivity: SyncActivity? {
        if case let .running(activity, false, false) = phase { return activity }
        return nil
    }

    private func scheduleDrop(at due: Date) {
        dropTimer?.invalidate()
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            self?.applyPendingDrop()
        }
        // .common so the drop still fires while the menu is open (menu
        // tracking runs the run loop outside the default mode).
        RunLoop.main.add(timer, forMode: .common)
        dropTimer = timer
    }

    private func refreshDisplay() {
        let new = currentDisplay()
        if new != display { display = new }
    }

    private func currentDisplay() -> DisplayState {
        switch phase {
        case .notRunning: .notRunning
        case .starting: .starting
        case let .failed(message): .failed(message)
        case .selfManaged(.notConfigured): .notConfigured
        case .selfManaged(.connecting): .connecting
        case .selfManaged(.unreachable): .unreachable
        case .selfManaged(.keyRejected): .keyRejected
        case .running(_, _, true): .attention
        case .running(_, true, _): .paused
        case let .running(activity, _, _):
            switch shown?.activity ?? activity {
            case .syncing: .syncing
            case .scanning: .scanning
            case .idle: .running
            }
        }
    }

    /// One-line status in the menu status-row's grammar (the Activity window's
    /// subtitle shares it). Failure text is the full message — surfaces with
    /// tight layouts truncate for themselves.
    var statusText: String {
        switch display {
        case .notRunning: "Not running"
        case .starting: "Starting…"
        case let .failed(message): message
        case .notConfigured: "Not configured"
        case .connecting: "Connecting…"
        case .unreachable: "Not reachable"
        case .keyRejected: "API key rejected"
        case .attention: "Can't access some folders"
        case .paused: "Paused"
        case .syncing: "Syncing…"
        case .scanning: "Scanning…"
        case .running: "Running"
        }
    }

    /// Sentence-form state summary — the icon tooltip and accessibility
    /// description (the zero-click reading of the icon).
    var summaryText: String {
        switch display {
        case .notRunning: "Syncthing is not running"
        case .starting: "Syncthing is starting"
        case let .failed(message): "Syncthing failed — \(message)"
        case .notConfigured: "Not connected to Syncthing — enter its address and API key in Settings"
        case .connecting: "Connecting to Syncthing"
        case .unreachable: "Syncthing is not reachable at the configured address"
        case .keyRejected: "Syncthing rejected the API key — check Settings"
        case .attention:
            "Syncthing can't access some folders — open Settings (Full Disk Access may be needed)"
        case .paused: "Syncthing is paused"
        case .syncing: "Syncthing is syncing"
        case .scanning: "Syncthing is scanning"
        case .running: "Syncthing is running"
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isPaused: Bool {
        if case .running(_, true, _) = phase { return true }
        return false
    }

    /// Running with a folder blocked on permissions (drives the Settings…
    /// caution badge alongside the display state).
    var needsAttention: Bool {
        display == .attention
    }
}
