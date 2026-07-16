### Added
- The Syncthing binary is now verified — signature and developer identity — at installation and before every launch.
- The app detects when Syncthing can't access a folder and alerts in the menu and in Settings, where the affected folders are named and the fix (usually Full Disk Access) is one click away.
- A documented way to inspect logs and report a problem: the app logs to the macOS unified log, Syncthing keeps its own rotating log file, and the README's new Troubleshooting section covers both.
- An automated test suite, run locally and in CI on every push.

### Changed
- The app reconnects to Syncthing automatically if its REST endpoint changes while running (for example, after regenerating the API key in Syncthing's settings) — no relaunch needed.

