import Foundation
import Security

/// Provenance checks for the managed Syncthing binary.
///
/// The official binary is Developer-ID signed by Syncthing's own company,
/// Kastelo AB (team `LQE5SYM783`) — the same stable identity macOS keys the
/// Full Disk Access grant on. Verifying that signature through the OS trust
/// stack (`SecStaticCode`) checks the *executable itself*: it holds no matter
/// where the archive, the checksum file, or the transport were tampered with.
enum BinaryVerifier {
    /// Syncthing's Apple Developer team (Kastelo AB).
    static let syncthingTeamID = "LQE5SYM783"

    /// The standard Developer-ID requirement, pinned to Syncthing's team:
    /// Apple's generic anchor, the Developer ID CA marker on the intermediate,
    /// the Developer ID Application marker on the leaf, and the team identifier.
    static let syncthingRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] "
        + "and certificate leaf[subject.OU] = \"\(syncthingTeamID)\""

    enum VerificationError: Error, Equatable, LocalizedError {
        /// The file couldn't be read as signed code at all.
        case unreadable(OSStatus)
        /// The requirement string didn't compile (a programming error).
        case badRequirement(OSStatus)
        /// The signature is missing, broken, or signed by someone else.
        case signatureInvalid(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unreadable(status):
                return "Syncthing binary couldn't be read for verification (\(status))"
            case let .badRequirement(status):
                return "Code-signing requirement didn't compile (\(status))"
            case let .signatureInvalid(status):
                return "Syncthing binary failed signature verification (\(status)) — not signed by Syncthing's developer"
            }
        }
    }

    /// Verify that the binary at `url` carries a valid Developer-ID signature
    /// from Syncthing's team, across all slices of the universal binary.
    static func verifySyncthingBinary(at url: URL) throws {
        try verify(url: url, requirement: syncthingRequirement)
    }

    static func verify(url: URL, requirement: String) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw VerificationError.unreadable(status)
        }
        var compiled: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw VerificationError.badRequirement(status)
        }
        status = SecStaticCodeCheckValidity(staticCode,
                                            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                            compiled)
        guard status == errSecSuccess else {
            throw VerificationError.signatureInvalid(status)
        }
    }

    /// Whether the file carries `com.apple.quarantine`. Our download path never
    /// sets it (no quarantine-aware layer touches the bytes — verified
    /// empirically 2026-07-16), so a quarantined install is an ASSUMPTION
    /// FAILURE: something in the environment changed, and installation should
    /// refuse loudly rather than proceed — and never silently clear a security
    /// marker it can't explain.
    static func isQuarantined(at url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}
