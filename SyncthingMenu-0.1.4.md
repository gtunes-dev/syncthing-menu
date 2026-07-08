### Added
- The menu bar icon now reflects live Syncthing activity: distinct marks for syncing (a nested progress loop) and paused, driven by Syncthing's event stream, alongside the existing idle and error states. The icon dims while Syncthing isn't running.
- Menu commands for common operations: **Rescan All** and a **Pause All Devices ⇄ Resume All Devices** toggle that reflects the current state.
- **Start Syncthing** appears in the menu when the daemon is stopped or has failed, so it can be restarted without quitting the app.
- When an update is available, the menu offers it directly — "Update Syncthing Menu to X" / "Update Syncthing to X" — with the same behavior as the Settings cards (major Syncthing updates are labeled and require this explicit click).
- Hovering the menu bar icon shows a live status summary, including pending update versions.

### Changed
- The status line in the menu is now fully readable — a colored state dot (green running / orange starting or paused / red failed) with full-contrast text — instead of a dimmed, disabled-looking item. It remains non-interactive.
- While Syncthing isn't running, the daemon-dependent menu items (Web UI, Folders, Rescan, Pause) are hidden rather than shown disabled.
- The menu bar status icons were redesigned for clarity at menu bar size: states no longer dim the mark (dimming now only ever means "not running"), each state changes the icon's silhouette, and the update badge floats cleanly instead of merging into the mark.
- Syncthing version numbers display without the "v" prefix everywhere (Settings, About, menu), matching the app's own version format.

