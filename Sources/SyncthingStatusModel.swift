import Foundation

/// Global Syncthing status as one observable value. The Activity window's
/// subtitle and toolbar feed off it; future surfaces can share it. Fed by
/// `AppDelegate` from the process-state push and the monitor's snapshot —
/// the same signals that drive the menu, so every surface tells the same
/// story in the same words.
final class SyncthingStatusModel: ObservableObject {
    enum Phase: Equatable {
        case notRunning
        case starting
        case running(activity: SyncActivity, paused: Bool, attention: Bool)
        case failed(String)
    }

    /// Main thread only (every publisher feeds UI).
    @Published private(set) var phase: Phase = .notRunning

    func update(_ new: Phase) {
        if new != phase { phase = new }
    }

    /// One-line status in the menu status-row's grammar. Priority mirrors the
    /// menu: attention > paused > syncing > scanning > running.
    var statusText: String {
        switch phase {
        case .notRunning: return "Not running"
        case .starting: return "Starting…"
        case .running(_, _, true): return "Can't access some folders"
        case .running(_, true, _): return "Paused"
        case .running(.syncing, _, _): return "Syncing…"
        case .running(.scanning, _, _): return "Scanning…"
        case .running: return "Running"
        case let .failed(message): return message
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
}
