import Foundation

/// Any decoded event carrying the per-subscription sequence id the stream
/// cursors on.
protocol StreamedEvent {
    var id: Int { get }
}

extension SyncthingAPI.Event: StreamedEvent {}
extension SyncthingAPI.ActivityEvent: StreamedEvent {}

/// The long-poll engine shared by `SyncthingMonitor` and `ActivityFeed`:
/// one parked `GET /rest/events` connection with push semantics — the request
/// blocks server-side until a matching event occurs or the server-side timeout
/// lapses (an empty batch), and is immediately re-issued. Idle cost is one
/// trivial localhost round-trip per ~50s; no timers, no busy polling. This is
/// the same mechanism Syncthing's own web GUI uses.
///
/// A filtered event subscription is created on first use and only reports
/// events from that moment on (verified live — there is NO usable history
/// replay for a fresh subscription). So the engine establishes the cursor
/// FIRST (`since=0&limit=1`, which also creates the subscription), then asks
/// the consumer to `seed` current state directly — a change landing mid-seed
/// has an id past the cursor and arrives in the first long-poll, no gap.
///
/// On ANY stream error the cursor is dropped and the consumer reseeded: event
/// ids are per-subscription and reset when the worker restarts, so keeping a
/// stale `since` could go silent forever. Consumers choose the failure policy:
/// with `failuresBeforeEscalation` set, persistent failures call `onEscalate`
/// once and stop the loop (the monitor's health-probe contract); without it,
/// the loop retries forever (the feed — the monitor is the session's probe).
///
/// Main-thread confined by the consumers' convention: the poll task is
/// @MainActor, awaits run the network work off-main, and every consumer
/// closure is invoked on main. The class itself stays nonisolated so
/// main-thread-by-convention owners (`SyncthingMonitor`) can construct and
/// stop it without isolation friction — configure (`retrySleep`) before
/// `start()`.
final class EventStream<E: StreamedEvent> {
    /// Server-side long-poll timeout, seconds (the request timeout is padded
    /// past it — see `SyncthingAPI.events`).
    static var pollTimeout: Int { 50 }

    private let label: String
    private let fetch: (_ since: Int, _ timeout: Int, _ limit: Int?) async throws -> [E]
    private let seed: @MainActor () async throws -> Void
    private let handle: @MainActor ([E]) async throws -> Void
    private let failuresBeforeEscalation: Int?
    private let onEscalate: (@MainActor () -> Void)?

    /// Sleeps between failed attempts. Injectable seam: tests exercise the
    /// failure/escalation path without real time passing.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - label: prefix for the stream's log lines.
    ///   - fetch: the filtered events call (the filter defines the server-side
    ///     subscription; a distinct filter is a distinct subscription).
    ///   - seed: rebuild consumer state by reading it directly — on start and
    ///     after any stream error.
    ///   - handle: merge one event batch. Called on EVERY wake, including the
    ///     empty ~50s timeout batches (consumers hang time-based sweeps here).
    ///     A throw is treated as a stream error: reseed.
    ///   - failuresBeforeEscalation: consecutive failures (with a 2s pause
    ///     each) tolerated before `onEscalate` fires and the loop stops;
    ///     nil retries forever.
    init(label: String,
         fetch: @escaping (_ since: Int, _ timeout: Int, _ limit: Int?) async throws -> [E],
         seed: @escaping @MainActor () async throws -> Void,
         handle: @escaping @MainActor ([E]) async throws -> Void,
         failuresBeforeEscalation: Int? = nil,
         onEscalate: (@MainActor () -> Void)? = nil) {
        self.label = label
        self.fetch = fetch
        self.seed = seed
        self.handle = handle
        self.failuresBeforeEscalation = failuresBeforeEscalation
        self.onEscalate = onEscalate
    }

    /// Start the loop. Replaces any prior run.
    func start() {
        stop()
        task = Task { @MainActor in await self.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    @MainActor
    private func run() async {
        var since = 0
        var needsSeed = true
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                if needsSeed {
                    // Cursor first (this also creates the server-side
                    // subscription), then seed — see the class doc.
                    since = try await fetch(0, 1, 1).last?.id ?? 0
                    try await seed()
                    needsSeed = false
                }
                let events = try await fetch(since, Self.pollTimeout, nil)
                guard !Task.isCancelled else { return }
                consecutiveFailures = 0
                if let first = events.first, since > 0, first.id > since + 1 {
                    // Ring overflow: the daemon buffers 1000 events per
                    // subscription and we fell behind. Events between are
                    // lost; the stream continues from here.
                    Log.monitor.log("\(self.label, privacy: .public) stream missed \(first.id - since - 1) events")
                }
                since = events.last.map { max(since, $0.id) } ?? since
                try await handle(events)
            } catch {
                guard !Task.isCancelled else { return }
                consecutiveFailures += 1
                // Always name the error: a silent deterministic failure here
                // once froze the monitor in an undiagnosable escalation loop.
                Log.monitor.log("\(self.label, privacy: .public) stream failure #\(consecutiveFailures): \(String(describing: error), privacy: .public)")
                if let limit = failuresBeforeEscalation, consecutiveFailures >= limit {
                    Log.monitor.log("\(self.label, privacy: .public) endpoint suspect after \(consecutiveFailures) failures — escalating")
                    onEscalate?()
                    return
                }
                since = 0
                needsSeed = true
                await retrySleep(2_000_000_000)
            }
        }
    }
}
