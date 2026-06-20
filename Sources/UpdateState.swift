import Foundation
import Combine

/// The update status of a single updatable component (Syncthing, or the app itself).
enum UpdateState: Equatable {
    /// Not yet checked.
    case unknown
    /// A check is in progress.
    case checking
    /// Running the latest available version.
    case upToDate
    /// An update is available. `isMajor` gates behavior: major updates always
    /// require explicit user consent and are never auto-installed.
    case available(version: String, isMajor: Bool)
    /// An update is currently being applied.
    case installing
}

/// A component that can report its version and update status, and be asked to
/// check or install. Modeled as a concrete `ObservableObject` base class (rather
/// than a protocol) so SwiftUI can observe it polymorphically through subclasses
/// — `MockUpdateSource` now, the real Syncthing/Sparkle sources later.
class UpdateSource: ObservableObject {
    /// Display name for this source's settings section, e.g. "Syncthing" or "App".
    let name: String

    /// The currently installed/running version, if known (e.g. "v2.1.1").
    @Published var currentVersion: String?

    /// The latest known update state.
    @Published var state: UpdateState = .unknown

    init(name: String) {
        self.name = name
    }

    /// Trigger a check for updates. Subclasses override.
    func checkNow() {}

    /// Apply the available update, if any. Subclasses override.
    func installAvailable() {}
}
