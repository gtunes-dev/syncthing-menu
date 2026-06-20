import Foundation

/// A simulated `UpdateSource` for building and exercising the UI before the real
/// Syncthing (REST) and app (Sparkle) sources exist.
///
/// - `checkNow()` transitions to `.checking`, then resolves to `checkResult`
///   after a short delay.
/// - `installAvailable()` simulates an install: `.installing`, then `.upToDate`
///   with `currentVersion` advanced to the version that was offered.
///
/// Set `checkResult` to drive any scenario: `.upToDate`, a minor
/// `.available(version:isMajor:false)`, or a major `.available(...isMajor:true)`.
final class MockUpdateSource: UpdateSource {
    /// What the next check will "discover".
    var checkResult: UpdateState

    init(name: String, currentVersion: String?, checkResult: UpdateState = .upToDate) {
        self.checkResult = checkResult
        super.init(name: name)
        self.currentVersion = currentVersion
    }

    override func checkNow() {
        state = .checking
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.state = self?.checkResult ?? .unknown
        }
    }

    override func installAvailable() {
        guard case let .available(version, _) = state else { return }
        state = .installing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.currentVersion = version
            self.state = .upToDate
        }
    }
}
