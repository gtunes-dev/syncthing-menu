import Foundation
import Testing
@testable import SyncthingMenu

/// The daemon-mode model: address normalization, endpoint configured-ness, and
/// the persistence contract (mode and connection fields under independent keys,
/// the API key in the secret store — never in defaults).
struct DaemonModeTests {

    private func makeSettings(defaults: UserDefaults? = nil,
                              secrets: InMemorySecretStore = InMemorySecretStore())
        -> (DaemonModeSettings, UserDefaults, InMemorySecretStore) {
        let suite = "DaemonModeTests-\(UUID().uuidString)"
        let d = defaults ?? UserDefaults(suiteName: suite)!
        return (DaemonModeSettings(defaults: d, secrets: secrets), d, secrets)
    }

    // MARK: - Port parsing

    @Test func parsesPortField() {
        // The pre-fill and any explicit port in range.
        #expect(SelfManagedEndpoint.port(from: "8384") == 8384)
        #expect(SelfManagedEndpoint.port(from: " 9000 ") == 9000)
        // Empty falls back to the default — exactly what the placeholder shows.
        #expect(SelfManagedEndpoint.port(from: "") == 8384)
        #expect(SelfManagedEndpoint.port(from: "   ") == 8384)
        // Out-of-range or non-numeric is unusable, not guessed at.
        #expect(SelfManagedEndpoint.port(from: "0") == nil)
        #expect(SelfManagedEndpoint.port(from: "65536") == nil)
        #expect(SelfManagedEndpoint.port(from: "-1") == nil)
        #expect(SelfManagedEndpoint.port(from: "abc") == nil)
        #expect(SelfManagedEndpoint.port(from: "127.0.0.1:8384") == nil)
    }

    @Test func buildsLoopbackURL() {
        #expect(SelfManagedEndpoint.guiURL(portText: "9000") == "http://127.0.0.1:9000")
        #expect(SelfManagedEndpoint.guiURL(portText: "") == "http://127.0.0.1:8384")
        #expect(SelfManagedEndpoint.guiURL(portText: "abc") == nil)
    }

    // MARK: - Endpoint source

    @Test func endpointRequiresKeyAndUsablePort() throws {
        let (settings, _, _) = makeSettings()
        let source = SelfManagedEndpointSource(settings: settings)

        // Port pre-fills to 8384, but a key is still required.
        #expect(try source.refreshEndpoint() == nil)
        #expect(!source.isConfigured)

        settings.selfManagedAPIKey = "  "                // whitespace ≠ a key
        #expect(try source.refreshEndpoint() == nil)

        settings.selfManagedAPIKey = "abc123"
        let endpoint = try #require(try source.refreshEndpoint())
        #expect(endpoint.guiURL == "http://127.0.0.1:8384")
        #expect(endpoint.apiKey == "abc123")
        #expect(source.isConfigured)

        settings.selfManagedPort = "not a port"
        #expect(try source.refreshEndpoint() == nil)
        #expect(!source.isConfigured)
    }

    // MARK: - Persistence

    /// The requirement the storage shape was designed around: switching modes
    /// never touches the connection fields — switch away and back, and they're
    /// exactly as left (including across a relaunch).
    @Test func fieldsSurviveModeSwitches() {
        let secrets = InMemorySecretStore()
        let suite = "DaemonModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = DaemonModeSettings(defaults: defaults, secrets: secrets)
        #expect(first.selfManagedPort == "8384")   // pre-filled, not empty
        first.mode = .selfManaged
        first.selfManagedPort = "9000"
        first.selfManagedAPIKey = "secret-key"
        first.mode = .managed
        first.mode = .selfManaged
        #expect(first.selfManagedPort == "9000")
        #expect(first.selfManagedAPIKey == "secret-key")

        // A fresh instance (relaunch) loads the same values.
        let second = DaemonModeSettings(defaults: defaults, secrets: secrets)
        #expect(second.mode == .selfManaged)
        #expect(second.selfManagedPort == "9000")
        #expect(second.selfManagedAPIKey == "secret-key")
    }

    /// The API key is a credential: it goes to the secret store and must never
    /// appear anywhere in defaults.
    @Test func apiKeyIsStoredAsSecretOnly() {
        let secrets = InMemorySecretStore()
        let suite = "DaemonModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = DaemonModeSettings(defaults: defaults, secrets: secrets)

        settings.selfManagedAPIKey = "super-secret"
        #expect(secrets.values.values.contains("super-secret"))
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(!persisted.values.contains { ($0 as? String) == "super-secret" })

        // Clearing the field clears the secret.
        settings.selfManagedAPIKey = ""
        #expect(secrets.values.isEmpty)
    }

    @Test func modeDefaultsToManaged() {
        let (settings, _, _) = makeSettings()
        #expect(settings.mode == .managed)
    }

    /// The lazy-load contract: constructing settings (every app launch) must
    /// not touch the secret store — the Keychain is consulted only when the
    /// key is actually needed, and only once (cached thereafter; a write
    /// primes the cache too).
    @Test func apiKeyIsReadLazilyAndOnce() {
        let (settings, _, secrets) = makeSettings()
        #expect(secrets.reads == 0)

        _ = settings.mode
        _ = settings.selfManagedPort
        #expect(secrets.reads == 0)      // other fields never consult it

        _ = settings.selfManagedAPIKey
        #expect(secrets.reads == 1)
        _ = settings.selfManagedAPIKey
        #expect(secrets.reads == 1)      // cached

        settings.selfManagedAPIKey = "k"
        #expect(settings.selfManagedAPIKey == "k")
        #expect(secrets.reads == 1)      // the write primed the cache
    }
}
