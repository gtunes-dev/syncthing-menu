import os

/// The app's unified-log categories — one `Logger` per functional area, all under
/// one subsystem so a single predicate extracts everything for a bug report:
///
///     log show --predicate 'subsystem == "io.github.gtunes-dev.SyncthingMenu"'
///
/// Level discipline: `.log` (notice) for the operational trail and `.error` for
/// failures — both persist to disk, so they're still there when a user reports
/// yesterday's problem. `.info`/`.debug` are memory-only; use them only for
/// chatter with no postmortem value.
///
/// Interpolated values are marked `privacy: .public` deliberately: nothing
/// sensitive is logged (never the API key; paths, versions, and states only),
/// and a `<private>`-redacted log is useless in a bug report.
enum Log {
    private static let subsystem = "io.github.gtunes-dev.SyncthingMenu"

    /// App lifecycle, bootstrap, and menu actions.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Daemon process supervision: spawn, stop ladder, exits.
    static let process = Logger(subsystem: subsystem, category: "process")
    /// Endpoint discovery and reconnection (DaemonSession).
    static let session = Logger(subsystem: subsystem, category: "session")
    /// Live daemon-state monitoring over the events API.
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    /// Both update channels + daemon binary provisioning.
    static let updates = Logger(subsystem: subsystem, category: "updates")
    /// The daemon's own output, relayed line-by-line from its stdout pipe.
    static let syncthing = Logger(subsystem: subsystem, category: "syncthing")
}
