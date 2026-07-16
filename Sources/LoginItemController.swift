import Foundation
import ServiceManagement

/// Controls whether the app launches at login, via `SMAppService.mainApp`
/// (macOS 13+).
///
/// The system owns the real state, so there's no `UserDefaults` flag — the
/// login-item registration *is* the source of truth. This type just reflects it
/// and toggles it.
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool

    init() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    /// Re-read the system state (e.g. after the app is reactivated).
    func refresh() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    /// Register or unregister the app as a login item.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Login item change to \(enabled) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
