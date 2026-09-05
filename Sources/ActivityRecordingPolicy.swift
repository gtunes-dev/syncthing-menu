import Foundation

/// WHEN the activity feed records. The feed's loop runs only while recording
/// is both wanted (this policy, or the open window) and possible (the
/// session has a live endpoint) — see `ActivityFeed`'s lifecycle section.
/// Raw values are the persisted form (`activity.recording`).
enum ActivityRecordingPolicy: String, CaseIterable {
    /// Record only while the Activity window is open (the default): zero
    /// daemon traffic while it is closed.
    case whileWindowOpen
    /// Record from launch, window or no window: the log is a rolling record
    /// of the session's witnessed activity.
    case always
}
