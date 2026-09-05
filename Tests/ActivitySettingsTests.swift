import Foundation
import Testing
@testable import SyncthingMenu

/// The activity recording preference: persisted under its own key, default
/// "while the window is open", unrecognized stored values fall back.
struct ActivitySettingsTests {
    @Test func recordingPolicyPersistsWithDefault() {
        let suite = "ActivitySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ActivitySettings(defaults: defaults).recording == .whileWindowOpen)

        let settings = ActivitySettings(defaults: defaults)
        settings.recording = .always
        #expect(defaults.string(forKey: "activity.recording") == "always")
        #expect(ActivitySettings(defaults: defaults).recording == .always)

        defaults.set("someday", forKey: "activity.recording")
        #expect(ActivitySettings(defaults: defaults).recording == .whileWindowOpen)
    }
}
