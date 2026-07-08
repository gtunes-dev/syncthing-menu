# Changelog

All notable changes to Syncthing Menu are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [0.1.3] - 2026-07-06

### Added
- App updates can now install automatically ("Install updates automatically" on the Syncthing Menu card): a found update downloads in the background and installs + relaunches with no dialogs. The same silent flow backs the Update button.
- Release Notes links wherever a version appears: the Settings card headers, an available update's "X available" status, and the About window.
- A "Last checked … ago" line under each update status in Settings.

### Changed
- Both update channels (Syncthing Menu and Syncthing) now share one update policy: check at launch and on a timer while enabled, optional automatic install, and never both installing at once. Turning "Automatically check for updates" off fully silences a channel — Check Now still works. Major Syncthing updates still require approval.
- Checking for app updates is now a silent probe reported in the Settings card, replacing Sparkle's dialog flow.

## [0.1.2] - 2026-06-23

### Added
- Folders submenu in the menu bar — lists your synced folders; selecting one opens it in Finder.

### Changed
- Reorganized the menu so the app's own items (About, Settings) group above the Syncthing items, and renamed them for clarity.
- The app bundle is now named **Syncthing Menu.app** (previously SyncthingMenu.app).

## [0.1.1] - 2026-06-23

### Added
- About box, opened from the menu bar, showing the app and Syncthing versions, the upstream attribution, and a link to the project.

### Changed
- Settings: the Syncthing Menu section now appears above the Syncthing section.

## [0.1.0] - 2026-06-23

### Added
- Initial release: a native macOS menu-bar app that downloads and runs the official Syncthing daemon, keeps it up to date, and updates itself via Sparkle.
- App-managed Syncthing updates (minor updates optionally automatic; major updates require approval).
- Guidance for the Full Disk Access and Local Network permissions Syncthing may need.
