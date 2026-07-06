import Foundation
import Combine

/// Persisted settings for one update channel (Syncthing Menu, or Syncthing), backed
/// by `UserDefaults` under a per-channel key prefix. The update policy in
/// `UpdateSource` reads `autoCheckEnabled` / `autoInstallEnabled` and records
/// `lastChecked`; the Settings UI binds the two toggles.
///
/// A plain `ObservableObject` (not `@AppStorage`) so the SwiftUI settings view and
/// the non-SwiftUI update policy share one source of truth.
final class UpdateChannelSettings: ObservableObject {
    /// Whether the channel checks for updates on its own — at launch and on a timer.
    @Published var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: key("autoCheck")) }
    }

    /// Whether a found update is installed automatically. Takes effect only when
    /// auto-check is also on (see `autoInstallEffective`).
    @Published var autoInstallEnabled: Bool {
        didSet { defaults.set(autoInstallEnabled, forKey: key("autoInstall")) }
    }

    /// When the channel last completed a check — drives the "Last checked" line.
    @Published var lastChecked: Date? {
        didSet {
            if let lastChecked {
                defaults.set(lastChecked, forKey: key("lastChecked"))
            } else {
                defaults.removeObject(forKey: key("lastChecked"))
            }
        }
    }

    /// Auto-install applies only alongside auto-check.
    var autoInstallEffective: Bool { autoCheckEnabled && autoInstallEnabled }

    private let defaults: UserDefaults
    private let prefix: String
    private func key(_ name: String) -> String { "\(prefix).\(name)" }

    init(defaults: UserDefaults, prefix: String,
         autoCheckDefault: Bool, autoInstallDefault: Bool) {
        self.defaults = defaults
        self.prefix = prefix
        defaults.register(defaults: [
            "\(prefix).autoCheck": autoCheckDefault,
            "\(prefix).autoInstall": autoInstallDefault,
        ])
        // Assigning in init does not fire `didSet`, so these loads don't re-persist.
        autoCheckEnabled = defaults.bool(forKey: "\(prefix).autoCheck")
        autoInstallEnabled = defaults.bool(forKey: "\(prefix).autoInstall")
        lastChecked = defaults.object(forKey: "\(prefix).lastChecked") as? Date
    }
}

/// App-wide settings: one `UpdateChannelSettings` per update channel. Persisted under
/// bundle id `io.github.gtunes-dev.SyncthingMenu`. Tests construct their own with an
/// isolated `UserDefaults`.
final class Settings {
    static let shared = Settings()

    let app: UpdateChannelSettings
    let syncthing: UpdateChannelSettings

    init(defaults: UserDefaults = .standard) {
        Self.migrateLegacyKeys(in: defaults)
        // Default: check on, install off (surface updates, but don't apply unattended).
        app = UpdateChannelSettings(defaults: defaults, prefix: "app",
                                    autoCheckDefault: true, autoInstallDefault: false)
        syncthing = UpdateChannelSettings(defaults: defaults, prefix: "syncthing",
                                          autoCheckDefault: true, autoInstallDefault: false)
    }

    /// One-time rename from the 0.1.x flat keys to the per-channel scheme, so an
    /// updated install keeps its toggles. Only values the user actually persisted
    /// migrate — the old registration domain is gone, so `object(forKey:)` can't see
    /// stale defaults. Each old key is removed after copying; a no-op thereafter.
    ///
    /// TEMPORARY — introduced in 0.1.3 (July 2026). Delete this (and its call above)
    /// once an update directly from ≤0.1.2 is implausible: any release from ~Jan 2027
    /// on, or sooner after a few intervening releases.
    private static func migrateLegacyKeys(in defaults: UserDefaults) {
        let renames = [
            "app.autoCheckEnabled": "app.autoCheck",
            "syncthing.autoCheckEnabled": "syncthing.autoCheck",
            "syncthing.autoInstallEnabled": "syncthing.autoInstall",
            "syncthing.lastCheck": "syncthing.lastChecked",
        ]
        for (old, new) in renames {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
    }
}
