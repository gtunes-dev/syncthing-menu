import Foundation
import Combine

/// App-wide user settings, backed by `UserDefaults`.
///
/// Deliberately a plain `ObservableObject` (not SwiftUI's `@AppStorage`) so that
/// both the SwiftUI settings view *and* the non-SwiftUI update coordinator can
/// read the same source of truth.
final class Settings: ObservableObject {
    /// Shared instance used throughout the app. Tests can construct their own
    /// with an isolated `UserDefaults`.
    static let shared = Settings()

    private let defaults: UserDefaults

    private enum Key {
        static let syncthingAutoCheck = "syncthing.autoCheckEnabled"
        static let syncthingAutoInstall = "syncthing.autoInstallEnabled"
        static let appAutoCheck = "app.autoCheckEnabled"
        static let lastSyncthingCheck = "syncthing.lastCheck"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.syncthingAutoCheck: true,    // default: ON  (check)
            Key.syncthingAutoInstall: false, // default: OFF (notify, don't act)
            Key.appAutoCheck: true,
        ])
        // Load persisted values. (Assigning in init does not fire `didSet`.)
        syncthingAutoCheckEnabled = defaults.bool(forKey: Key.syncthingAutoCheck)
        syncthingAutoInstallEnabled = defaults.bool(forKey: Key.syncthingAutoInstall)
        appAutoCheckEnabled = defaults.bool(forKey: Key.appAutoCheck)
        lastSyncthingCheck = defaults.object(forKey: Key.lastSyncthingCheck) as? Date
    }

    /// Whether the app periodically checks for new Syncthing releases.
    @Published var syncthingAutoCheckEnabled: Bool {
        didSet { defaults.set(syncthingAutoCheckEnabled, forKey: Key.syncthingAutoCheck) }
    }

    /// Whether minor/patch Syncthing updates are installed automatically.
    /// Only meaningful when `syncthingAutoCheckEnabled` is true (the UI slaves it),
    /// and never applies to major updates — those always require explicit consent.
    @Published var syncthingAutoInstallEnabled: Bool {
        didSet { defaults.set(syncthingAutoInstallEnabled, forKey: Key.syncthingAutoInstall) }
    }

    /// Whether the app checks for updates to itself (maps to Sparkle later).
    @Published var appAutoCheckEnabled: Bool {
        didSet { defaults.set(appAutoCheckEnabled, forKey: Key.appAutoCheck) }
    }

    /// Timestamp of the last Syncthing update check, for the "Last checked…" line.
    @Published var lastSyncthingCheck: Date? {
        didSet {
            if let date = lastSyncthingCheck {
                defaults.set(date, forKey: Key.lastSyncthingCheck)
            } else {
                defaults.removeObject(forKey: Key.lastSyncthingCheck)
            }
        }
    }

    /// Auto-install only takes effect when auto-check is also on. The update
    /// coordinator should consult this rather than the raw flag.
    var syncthingAutoInstallEffective: Bool {
        syncthingAutoCheckEnabled && syncthingAutoInstallEnabled
    }
}
