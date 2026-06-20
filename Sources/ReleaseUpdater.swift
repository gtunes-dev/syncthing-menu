import Foundation

/// Resolves, downloads, and installs the official Syncthing macOS binary,
/// keeping it current independently of this app's own release cadence — the
/// core design goal: the daemon never drifts behind upstream.
///
/// Planned responsibilities (not yet implemented):
/// - Query https://api.github.com/repos/syncthing/syncthing/releases/latest
/// - Select the macOS universal asset and download it.
/// - Verify the published SHA-256 before swapping it into place.
/// - Install into Application Support (user-writable, so no re-signing of the app).
///
/// Open decision (see README): whether updates are app-managed (poll + replace)
/// or delegated to Syncthing's own signature-verified self-upgrader.
struct ReleaseUpdater {
    // TODO: implement release resolution + checksum-verified download.
}
