import Foundation
import Combine
import Security

/// Which Syncthing this app uses — the single source of truth for the mode.
///
/// - `managed`: Syncthing Menu downloads, launches, supervises, and updates its
///   own isolated Syncthing instance (everything the app has always done).
/// - `selfManaged`: the user runs Syncthing themselves; Syncthing Menu only
///   connects to it (address + API key) and presents it. Nothing process- or
///   update-related applies: no spawn, no bootstrap, no update checks, no
///   `autoUpgradeIntervalH` enforcement, and quitting never stops their daemon.
enum DaemonMode: String {
    case managed
    case selfManaged
}

/// Minimal secret persistence — the self-managed API key is a credential the
/// user hands us, so it lives in the Keychain, not UserDefaults. Protocol so
/// tests substitute an in-memory store.
protocol SecretStore: AnyObject {
    func read(_ name: String) -> String?
    func write(_ name: String, value: String)
}

/// Generic-password Keychain items under the app's bundle-id service.
final class KeychainSecretStore: SecretStore {
    private let service = "io.github.gtunes-dev.SyncthingMenu"

    private func baseQuery(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    func read(_ name: String) -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ name: String, value: String) {
        guard !value.isEmpty else {
            SecItemDelete(baseQuery(name) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery(name) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(name)
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // A silently-lost credential is a confusing next launch — leave a trace.
            Log.app.error("Keychain write for \(name, privacy: .public) failed: \(status)")
        }
    }
}

/// The daemon-mode choice and the self-managed connection values.
///
/// The mode and the connection fields persist under independent keys, so
/// switching modes never touches the entered address/key — switch away and
/// back, and they're exactly as left. An `ObservableObject` (the Settings UI
/// binds the pop-up and fields; `AppDelegate` observes mode and field changes
/// to drive the session).
final class DaemonModeSettings: ObservableObject {
    @Published var mode: DaemonMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// The self-managed daemon's GUI port as the user typed it (the host is
    /// always 127.0.0.1 — self-managed is scoped to local instances, so only
    /// the port is asked for). Starts pre-filled with Syncthing's default 8384;
    /// an emptied field falls back to that default (the field's placeholder
    /// says so). Parsing happens at the endpoint boundary
    /// (`SelfManagedEndpoint`), so editing round-trips verbatim.
    @Published var selfManagedPort: String {
        didSet {
            defaults.set(selfManagedPort, forKey: Self.portKey)
            connectionFieldEdited.send()
        }
    }

    /// Fires on every edit of a self-managed connection field (port or API
    /// key). `AppDelegate` debounces this to re-arm endpoint discovery; the
    /// values themselves are re-read by the endpoint source at connect time,
    /// so the signal carries no payload.
    let connectionFieldEdited = PassthroughSubject<Void, Never>()

    /// The self-managed daemon's API key. Persisted in the Keychain, and read
    /// from it LAZILY — on first access, never at init — so a launch that
    /// doesn't use self-managed mode doesn't touch the Keychain at all.
    /// (Reading an existing item from a differently-signed build — every
    /// ad-hoc-signed dev rebuild — triggers macOS's confidential-information
    /// prompt; release builds have a stable Developer ID identity and never
    /// prompt. Not reading is still better than reading needlessly.)
    var selfManagedAPIKey: String {
        get {
            if let loadedAPIKey { return loadedAPIKey }
            let value = secrets.read(Self.apiKeySecretName) ?? ""
            loadedAPIKey = value
            return value
        }
        set {
            objectWillChange.send()
            loadedAPIKey = newValue
            secrets.write(Self.apiKeySecretName, value: newValue)
            connectionFieldEdited.send()
        }
    }

    /// The Keychain value once read (or written); nil = not consulted yet.
    private var loadedAPIKey: String?

    private let defaults: UserDefaults
    private let secrets: SecretStore

    private static let modeKey = "daemon.mode"
    private static let portKey = "daemon.selfManaged.port"
    private static let apiKeySecretName = "daemon.selfManaged.apiKey"

    init(defaults: UserDefaults, secrets: SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        // Assigning in init does not fire `didSet`, so these loads don't re-persist.
        // The API key is deliberately NOT loaded here — see `selfManagedAPIKey`.
        mode = defaults.string(forKey: Self.modeKey).flatMap(DaemonMode.init) ?? .managed
        selfManagedPort = defaults.string(forKey: Self.portKey)
            ?? String(SelfManagedEndpoint.defaultPort)
    }
}
