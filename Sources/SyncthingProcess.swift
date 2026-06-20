import Foundation

/// Supervises the `syncthing` binary as a child process.
///
/// Planned responsibilities (not yet implemented):
/// - Launch `syncthing` with `--no-browser` against a managed home directory.
/// - Restart with backoff on unexpected exit; surface lifecycle state.
/// - Stop the process cleanly on app termination.
/// - Detect an already-running/externally-installed daemon and avoid duplicates.
final class SyncthingProcess {
    // TODO: implement subprocess supervision.
}
