import Foundation

/// Reads a managed Syncthing `config.xml`. **Read-only** — we never write to
/// Syncthing's config file. The GUI port comes from a CLI flag (or Syncthing's own
/// probing), and the one option we enforce (`autoUpgradeIntervalH`) is set through
/// the REST API, not by editing this file. So a user changing things in Syncthing's
/// own web GUI is always respected: we just re-read.
struct SyncthingConfig {
    private let document: XMLDocument

    init(contentsOf url: URL) throws {
        self.document = try XMLDocument(contentsOf: url)
    }

    /// The API key Syncthing generated — needed to call its REST API.
    var apiKey: String? { firstNode("//gui/apikey")?.stringValue }

    /// The configured GUI address. May be the literal `"dynamic"` (Syncthing picks a
    /// free port at startup) rather than a concrete `host:port`.
    var guiAddress: String? { firstNode("//gui/address")?.stringValue }

    var guiUsesTLS: Bool {
        (firstNode("//gui") as? XMLElement)?.attribute(forName: "tls")?.stringValue == "true"
    }

    /// The concrete GUI port, or nil if the address is `"dynamic"`/unparseable.
    var guiPort: UInt16? {
        guard let port = guiAddress?.split(separator: ":").last else { return nil }
        return UInt16(port)
    }

    /// A concrete GUI URL when the address is a real `host:port`; nil for `"dynamic"`.
    var concreteGUIURL: String? {
        guard let address = guiAddress, guiPort != nil else { return nil }
        return "\(guiUsesTLS ? "https" : "http")://\(address)"
    }

    private func firstNode(_ xpath: String) -> XMLNode? {
        (try? document.nodes(forXPath: xpath))?.first
    }
}
