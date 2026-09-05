import Foundation
import Combine

/// The Activity window's preferences: when the feed records. An
/// `ObservableObject` (the Settings UI binds the pop-up; `AppDelegate`
/// forwards changes to the feed). Persisted under `activity.recording`;
/// an unrecognized stored value falls back to the default.
final class ActivitySettings: ObservableObject {
    @Published var recording: ActivityRecordingPolicy {
        didSet { defaults.set(recording.rawValue, forKey: Self.recordingKey) }
    }

    private let defaults: UserDefaults
    private static let recordingKey = "activity.recording"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Assigning in init does not fire `didSet`, so the load doesn't re-persist.
        recording = defaults.string(forKey: Self.recordingKey)
            .flatMap(ActivityRecordingPolicy.init) ?? .whileWindowOpen
    }
}
