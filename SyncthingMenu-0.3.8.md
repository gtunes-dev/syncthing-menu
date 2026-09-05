### Added
- A "Record activity" setting: keep recording sync activity while the Activity window is closed, or only while it is open (the default).
- The Activity window keeps its log when closed and reopened.
- The Activity log notes when recording started or paused and when the connection to Syncthing was lost or restored.
- The Activity log records folder and device events: pause and resume, devices going online or offline, a folder stopping with an error, and the file watcher failing or recovering. A filter switch hides them.
- A Clear button (⌘K) empties the Activity log.

### Changed
- Searching by name in the Activity window shows only file rows.
- Batches of up to 100 changed files are listed individually in the Activity window; only larger batches are summarized as "N changes" (previously 25).

