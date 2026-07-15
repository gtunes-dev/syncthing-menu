import Foundation

/// The session's discovery source — how it learns the daemon's current REST
/// endpoint. `SyncthingProcess.refreshEndpoint()` is the production conformer
/// (it re-reads `config.xml`); tests substitute a scripted one.
protocol EndpointSource: AnyObject {
    func refreshEndpoint() throws -> SyncthingProcess.Endpoint?
}

extension SyncthingProcess: EndpointSource {}

/// Owns "the current REST endpoint" as observable state — the session layer of
/// the supervision model (design.md § Process & session supervision).
///
/// Process-alive ≠ API-reachable: the worker owns the HTTP server and can restart
/// or change identity under a live monitor PID (a Web-UI settings change can
/// rotate the API key, or — when the config has a concrete GUI address — move the
/// listener). The session reconciles that: given the process's lifecycle state, it
/// discovers the endpoint, verifies it answers, applies the enforced invariant,
/// and publishes a ready-to-use `SyncthingAPI`. Consumers subscribe to the session
/// and stop caring *why* the endpoint changed — fresh launch, post-upgrade
/// re-root, and key/port rotation all look identical from their side.
///
/// Main-thread confined like the update policy engine: state, the generation
/// counter, and all callbacks live on main; async attempts hop back to main and
/// re-check their generation before acting.
final class DaemonSession {
    enum State: Equatable {
        /// The daemon isn't running (or is going down); there is no endpoint.
        case unavailable
        /// The daemon claims to be running; the endpoint is being discovered,
        /// verified, or re-verified after a suspicion. Consumers keep whatever
        /// they had — this state is transient and resolves to one of the others.
        case connecting
        /// A verified endpoint: `/rest/system/version` answered and the
        /// no-self-upgrade invariant has been applied.
        case connected(SyncthingAPI)
    }

    /// Called on the main thread on every state change.
    var onChange: ((State) -> Void)?

    private(set) var state: State = .unavailable {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private let endpoints: any EndpointSource
    /// Bumped whenever the ground truth shifts (process transition or suspicion);
    /// an in-flight connect loop from an older generation abandons itself.
    private var generation = 0

    /// Delay between failed connect attempts: starts snappy (daemon startup takes
    /// ~a second), backs off toward a lazy retry while the endpoint stays dark.
    private static let initialRetryDelay: UInt64 = 500_000_000        // 0.5s
    private static let maxRetryDelay: UInt64 = 15_000_000_000         // 15s

    /// Sleeps between connect attempts. Injectable seam: tests run the retry/
    /// backoff loop without real time passing and assert the delays requested.
    var retrySleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    init(endpoints: any EndpointSource) {
        self.endpoints = endpoints
    }

    // MARK: - Inputs

    /// The process layer's lifecycle report (wired from
    /// `SyncthingProcess.onStateChange`). Running begins endpoint discovery;
    /// everything else tears the session down. `isTerminating` needs no special
    /// case here: a quit stops the daemon, which lands here as `.stopped`.
    func processStateChanged(_ processState: SyncthingProcess.State) {
        generation &+= 1
        switch processState {
        case .running:
            state = .connecting
            runConnectLoop(generation: generation)
        case .stopped, .starting, .failed:
            state = .unavailable
        }
    }

    /// The monitor's escalation: the endpoint stopped answering while the process
    /// still claims to be running (worker restart, port move, key rotation).
    /// Re-discover and re-verify; publishes `.connected` again when the endpoint
    /// answers — same identity or a new one.
    func endpointSuspect() {
        guard case .connected = state else { return }
        generation &+= 1
        state = .connecting
        runConnectLoop(generation: generation)
    }

    /// The endpoint if currently connected — for one-shot consumers (menu actions).
    var api: SyncthingAPI? {
        if case let .connected(api) = state { return api }
        return nil
    }

    // MARK: - Reconciliation

    /// Discover → verify → enforce → publish, retrying with backoff for as long as
    /// this generation stands (i.e. while the process still claims running and no
    /// newer transition superseded us). Deliberately never gives up on its own:
    /// "process up but endpoint dark" is a state to keep reconciling, and every
    /// terminal condition arrives as a process transition that bumps the generation.
    private func runConnectLoop(generation token: Int) {
        Task { @MainActor in
            var delay = Self.initialRetryDelay
            while self.generation == token {
                if let endpoint = try? self.endpoints.refreshEndpoint(),
                   let key = endpoint.apiKey,
                   let url = URL(string: endpoint.guiURL) {
                    let api = SyncthingAPI(baseURL: url, apiKey: key)
                    if (try? await api.systemVersion()) != nil {
                        guard self.generation == token else { return }
                        // Enforced invariant, reapplied on every (re)connect: the
                        // daemon must never self-upgrade — Syncthing Menu owns
                        // updates (idempotent PATCH; a Web-UI edit that re-enabled
                        // it is corrected on the reconnect its config save causes).
                        try? await api.setAutoUpgradeIntervalH(0)
                        guard self.generation == token else { return }
                        NSLog("[Session] connected: \(endpoint.guiURL)")
                        self.state = .connected(api)
                        return
                    }
                }
                await self.retrySleep(delay)
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }
}
