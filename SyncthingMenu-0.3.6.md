### Fixed
- Fixes a regression introduced in 0.3.5: a Syncthing update could disturb macOS folder permissions — showing an unexpected permissions prompt, or leaving Syncthing unable to access protected folders until Syncthing Menu was relaunched.
- Properly fixes the issue 0.3.5 set out to fix: a Syncthing update could leave Syncthing stopped with an error until it was started manually. Updates now install at a quiet moment and Syncthing is relaunched cleanly right after.

### Changed
- The menu's Syncthing status shows "Updating…" while a Syncthing update installs, matching the Settings window.

