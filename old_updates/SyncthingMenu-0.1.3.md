### Added
- App updates can now install automatically ("Install updates automatically" on the Syncthing Menu card): a found update downloads in the background and installs + relaunches with no dialogs. The same silent flow backs the Update button.
- Release Notes links wherever a version appears: the Settings card headers, an available update's "X available" status, and the About window.
- A "Last checked … ago" line under each update status in Settings.

### Changed
- Both update channels (Syncthing Menu and Syncthing) now share one update policy: check at launch and on a timer while enabled, optional automatic install, and never both installing at once. Turning "Automatically check for updates" off fully silences a channel — Check Now still works. Major Syncthing updates still require approval.
- Checking for app updates is now a silent probe reported in the Settings card, replacing Sparkle's dialog flow.

