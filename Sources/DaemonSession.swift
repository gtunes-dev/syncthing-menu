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
/// listener). The session reconciles that: given that an endpoint is expected, it
/// discovers it, verifies it answers, applies the enforced invariant (managed
/// mode only), and publishes a ready-to-use `SyncthingAPI`. Consumers subscribe
/// to the session and stop caring *why* the endpoint changed — fresh launch,
/// post-upgrade re-root, and key/port rotation all look identical from their
/// side. Self-managed mode reuses all of this with a different discovery source
/// (the user-entered endpoint) and no process driving the lifecycle.
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
        /// A verified endpoint: `/rest/system/version` answered (and, where
        /// enforced, the no-self-upgrade invariant has been applied).
        case connected(SyncthingAPI)
    }

    /// Why a connect attempt failed — surfaced so self-managed mode can tell
    /// "your daemon isn't answering" (actionable at the daemon) from "your
    /// API key is wrong" (actionable in our Settings).
    enum ProbeFailure: Equatable {
        /// No usable answer at the connection level (refused, timeout, or a
        /// non-auth HTTP status).
        case unreachable
        /// The endpoint answered 401/403 — a wrong or rotated API key.
        case apiKeyRejected
    }

    /// Called on the main thread on every state change.
    var onChange: ((State) -> Void)?

    /// Called on the main thread after each failed verification attempt while
    /// a connect loop runs. Managed mode leaves this unset (its retries are an
    /// internal detail); self-managed mode renders it as connection status.
    var onProbeFailure: ((ProbeFailure) -> Void)?

    private(set) var state: State = .unavailable {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private let endpoints: any EndpointSource
    /// Whether a (re)connect enforces `autoUpgradeIntervalH = 0` on the daemon.
    /// True for the managed daemon (Syncthing Menu owns its updates); false in
    /// self-managed mode — that daemon's update behavior is the user's, and we
    /// never write config we don't own.
    private let enforcesNoSelfUpgrade: Bool
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

    init(endpoints: any EndpointSource, enforcesNoSelfUpgrade: Bool = true) {
        self.endpoints = endpoints
        self.enforcesNoSelfUpgrade = enforcesNoSelfUpgrade
    }

    // MARK: - Inputs

    /// The session's ground-truth input: should an endpoint exist right now?
    /// In managed mode `processStateChanged` derives this from the process
    /// lifecycle; in self-managed mode it's true for as long as the mode is
    /// active (there is no process — "endpoint dark" is a state to keep
    /// reconciling, never a terminal one). Calling it again while already
    /// expected starts a fresh discovery loop (new generation, snappy
    /// backoff) — how field edits in Settings take effect immediately.
    func setEndpointExpected(_ expected: Bool) {
        generation &+= 1
        if expected {
            state = .connecting
            runConnectLoop(generation: generation)
        } else {
            state = .unavailable
        }
    }

    /// The process layer's lifecycle report (wired from
    /// `SyncthingProcess.onStateChange`). Running begins endpoint discovery;
    /// everything else tears the session down. `isTerminating` needs no special
    /// case here: a quit stops the daemon, which lands here as `.stopped`.
    func processStateChanged(_ processState: SyncthingProcess.State) {
        switch processState {
        case .running:
            setEndpointExpected(true)
        case .stopped, .starting, .failed:
            setEndpointExpected(false)
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
                    do {
                        _ = try await api.systemVersion()
                        guard self.generation == token else { return }
                        if self.enforcesNoSelfUpgrade {
                            // Enforced invariant, reapplied on every (re)connect: the
                            // managed daemon must never self-upgrade — Syncthing Menu
                            // owns updates (idempotent PATCH; a Web-UI edit that
                            // re-enabled it is corrected on the reconnect its config
                            // save causes).
                            try? await api.setAutoUpgradeIntervalH(0)
                            guard self.generation == token else { return }
                        }
                        Log.session.log("connected: \(endpoint.guiURL, privacy: .public)")
                        self.state = .connected(api)
                        return
                    } catch {
                        guard self.generation == token else { return }
                        self.onProbeFailure?(Self.classify(error))
                    }
                }
                await self.retrySleep(delay)
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }

    private static func classify(_ error: Error) -> ProbeFailure {
        if case let SyncthingAPI.APIError.http(status) = error,
           status == 401 || status == 403 {
            return .apiKeyRejected
        }
        return .unreachable
    }
}
