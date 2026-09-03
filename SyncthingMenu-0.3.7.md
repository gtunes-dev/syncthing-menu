### Changed
- The Activity window is redesigned as a live activity log. It opens empty and records sync events as they happen — a change detected, a file sending to or arriving from another device, a delivery confirmed, a failure — one row per event, newest first, each naming the file and the device involved. Nothing is replayed from before the window opened, rows never change once written, and closing the window clears it.
- Very large batches of changes (an app churning thousands of files at once) are summarized as single "N changes" rows instead of flooding the log; files actually transferring still appear individually.
- Deleted files show their name struck through, from detection through delivery.
- The Activity window toolbar gained a search field: type part of a file name to follow just that file's activity as it happens.
- The Pause All and Rescan All buttons were removed from the Activity window; those commands live in the menu.

### Fixed
- The Activity window no longer shows files as waiting to sync when they already finished syncing.
- During large syncs, files appear in the Activity window as they actually transfer, and each file's delivery is confirmed individually — including when a confirmation slips past the live event stream.

