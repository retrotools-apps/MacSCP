import Foundation
import Security

/// Abstraction over the secret store. Production: macOS keychain.
/// Secrets are addressed via the session id and NEVER appear in the
/// session JSON.
/// The secret is either a password (authKind .password) or the passphrase
/// of a private key (authKind .privateKey; empty = unencrypted key).
public protocol SecretStore: Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws
    func password(for sessionID: UUID) throws -> String?
    func deletePassword(for sessionID: UUID) throws
}

public struct KeychainError: Error, LocalizedError, Equatable, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? String(status)
    }
}

/// The application service uses the common, launch-unlocked vault. Explicit
/// custom services retain independent storage for isolated tools and tests.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "retroTools.MacSCP") {
        self.service = service
    }

    private func vault(for slot: UUID) -> CredentialVault {
        CredentialVault(
            legacy: KeychainItemStore(service: service, usesDataProtection: false),
            protected: KeychainItemStore(service: service, usesDataProtection: true),
            canUseProtectedStorage: CredentialProtection.hasSignedKeychainIdentity,
            preferProtectedStorage: service == CredentialProtection.service
                && (CredentialProtection.isEnabled || CredentialProtection.isProtected(slot)))
    }

    public func savePassword(_ password: String, for sessionID: UUID) throws {
        if service == ApplicationIdentity.bundleIdentifier {
            try SharedCredentialVault.shared.savePassword(password, for: sessionID)
            return
        }
        try CredentialAccessGate.operation {
            let vault = vault(for: sessionID)
            try vault.savePassword(password, for: sessionID)
            if service == CredentialProtection.service, vault.preferProtectedStorage {
                CredentialProtection.mark(sessionID, protected: true)
            }
        }
    }

    public func password(for sessionID: UUID) throws -> String? {
        if service == ApplicationIdentity.bundleIdentifier {
            return try SharedCredentialVault.shared.password(for: sessionID)
        }
        return try CredentialAccessGate.operation { try vault(for: sessionID).password(for: sessionID) }
    }

    public func deletePassword(for sessionID: UUID) throws {
        if service == ApplicationIdentity.bundleIdentifier {
            try SharedCredentialVault.shared.deletePassword(for: sessionID)
            return
        }
        try CredentialAccessGate.operation {
            try vault(for: sessionID).deletePassword(for: sessionID)
            if service == CredentialProtection.service { CredentialProtection.mark(sessionID, protected: false) }
        }
    }
}
