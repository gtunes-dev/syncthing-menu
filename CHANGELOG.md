# Changelog

All notable changes to Syncthing Menu are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- An Activity window (menu: Activity…) showing Syncthing's file-level activity live: each change's file and folder, which device made the change, and how far along it is — waiting to sync, actively transferring, delivered to another device, applied on this Mac, or failed (with the error shown on hover). The view can be filtered by change type and origin, sorted by any column (Finder-style), and kept above other windows with the pin button; holding Option turns the menu item into "Activity (Reset Layout)…", which restores the window's default size, columns, filters, and settings. The window costs nothing while closed — the app follows Syncthing's activity stream only while it's open.

### Changed
- The menu status line, icon tooltip, and Activity window now distinguish Scanning (checking local files for changes) from Syncing (transferring data between devices).

### Fixed
- On macOS 26 and later, the Settings… menu item no longer loses the gear icon the system gives it.

## [0.2.1] - 2026-07-16

### Fixed
- Automatic update checks now keep their schedule on Macs that sleep. The check timers previously counted only awake time, so on a laptop "daily" could mean every several days; a check whose time passes during sleep now runs at the next wake. A failed check (offline, Wi-Fi still reconnecting) also retries within about 15 minutes instead of waiting for the next scheduled check.

## [0.2.0] - 2026-07-16

### Added
- The Syncthing binary is now verified — signature and developer identity — at installation and before every launch.
- The app detects when Syncthing can't access a folder and alerts in the menu and in Settings, where the affected folders are named and the fix (usually Full Disk Access) is one click away.
- A documented way to inspect logs and report a problem: the app logs to the macOS unified log, Syncthing keeps its own rotating log file, and the README's new Troubleshooting section covers both.
- An automated test suite, run locally and in CI on every push.

### Changed
- The app reconnects to Syncthing automatically if its REST endpoint changes while running (for example, after regenerating the API key in Syncthing's settings) — no relaunch needed.

## [0.1.8] - 2026-07-09

### Changed
- Two menu items have shorter names: "Syncthing Menu Settings…" is now "Settings…", and "Open Syncthing Web UI" is now "Open Syncthing".

## [0.1.7] - 2026-07-09

### Changed
- Clicking Update for a Syncthing Menu update now opens Sparkle's standard update window — always in the foreground, never hidden behind other windows — where the release notes can be reviewed before choosing to install. "Skip This Version" (or just closing the window) returns to Settings with the update still offered, so the decision can be revisited at any time. The window carries only that decision: Sparkle's own "automatically download and install updates" checkbox is not shown — the checkbox in Settings remains the single control for automatic installs. Automatic installs themselves remain fully silent, and the app keeps checking for newer releases while an update is pending, so the newest version is always the one offered.

## [0.1.6] - 2026-07-08

### Changed
- The About box now presents Syncthing exactly like Syncthing Menu: matching logo (sized to match the app icon's visible art), name, version, and Release Notes link.
- Syncthing's own Web UI no longer advertises Syncthing upgrades — the upgrade banner and button are gone. Syncthing Menu is now the single place Syncthing updates are offered and installed, so an update can never bypass the app's handling (which keeps Full Disk Access intact across upgrades). Checking is done against Syncthing's official releases feed; installing still uses Syncthing's own built-in, verified upgrade mechanism, initiated by the app.

## [0.1.5] - 2026-07-08

### Fixed
- App updates now actually install silently. Sparkle was quietly rejecting the app's silent-install configuration and routing every update — including the Update button — through its own interactive dialog, which could appear hidden behind other windows. Updating *to* this version still uses the old flow; updates *from* it on are silent.
- If Sparkle ever does need user interaction for an update (e.g. installing would require admin authorization), its dialog now comes to the front instead of hiding behind other windows, and the update completes there.

## [0.1.4] - 2026-07-07

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
