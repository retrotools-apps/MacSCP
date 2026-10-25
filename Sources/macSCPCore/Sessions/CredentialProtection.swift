import Foundation
import LocalAuthentication
import Security
import Synchronization

public enum CredentialProtectionError: Error, LocalizedError, Sendable {
    case signatureRequired, biometricsUnavailable, verificationFailed, busy

    public var errorDescription: String? {
        switch self {
        case .signatureRequired: return CoreL10n.string("core.credentials.signatureRequired")
        case .biometricsUnavailable: return CoreL10n.string("core.credentials.biometricsUnavailable")
        case .verificationFailed: return CoreL10n.string("core.credentials.verificationFailed")
        case .busy: return CoreL10n.string("core.credentials.busy")
        }
    }
}

/// Backend-independent migration. Authentication failures never remove the
/// source, and a read-back mismatch cannot be reported as successful protection.
enum CredentialMigration {
    static func migrate(slots: [UUID], from source: any SecretStore, to target: any SecretStore,
                        didVerify: (UUID) -> Void = { _ in }, didMigrate: (UUID) -> Void = { _ in }) throws -> Int {
        var count = 0
        for slot in slots {
            try Task.checkCancellation()
            guard let original = try source.password(for: slot) else { continue }
            if let existing = try target.password(for: slot) {
                // A newer protected value may have been saved after an earlier
                // interrupted migration. Never overwrite either version blindly.
                guard existing == original else { throw CredentialProtectionError.verificationFailed }
            } else {
                try target.savePassword(original, for: slot)
            }
            guard try target.password(for: slot) == original else {
                throw CredentialProtectionError.verificationFailed
            }
            guard try source.password(for: slot) == original else {
                throw CredentialProtectionError.verificationFailed
            }
            didVerify(slot)
            try source.deletePassword(for: slot)
            didMigrate(slot)
            count += 1
        }
        return count
    }
}

/// A protected read is attempted first, never replaced by an unprotected read
/// after cancellation or an authentication error. Mixed stores are supported
/// so an interrupted migration can be retried without losing migrated entries.
struct CredentialVault: SecretStore {
    let legacy: any SecretStore
    let protected: any SecretStore
    let canUseProtectedStorage: Bool
    let preferProtectedStorage: Bool

    func password(for sessionID: UUID) throws -> String? {
        if canUseProtectedStorage {
            if let value = try protected.password(for: sessionID) { return value }
        } else if preferProtectedStorage {
            throw CredentialProtectionError.signatureRequired
        }
        if preferProtectedStorage { return nil }
        return try legacy.password(for: sessionID)
    }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        if preferProtectedStorage {
            guard canUseProtectedStorage else { throw CredentialProtectionError.signatureRequired }
            try protected.savePassword(password, for: sessionID)
        } else if canUseProtectedStorage, try protected.password(for: sessionID) != nil {
            // Never downgrade an already protected item after a partial migration.
            try protected.savePassword(password, for: sessionID)
        } else {
            try legacy.savePassword(password, for: sessionID)
        }
    }

    func deletePassword(for sessionID: UUID) throws {
        if canUseProtectedStorage { try protected.deletePassword(for: sessionID) }
        else if preferProtectedStorage { throw CredentialProtectionError.signatureRequired }
        try legacy.deletePassword(for: sessionID)
    }
}

/// A short state lock, never held across Keychain or biometric UI. Migration
/// refuses concurrent access rather than blocking the main actor behind a dialog.
enum CredentialAccessGate {
    private struct State { var operations = 0; var migrating = false }
    private static let state = Mutex(State())

    static func operation<T>(_ body: () throws -> T) throws -> T {
        try state.withLock { value in
            guard !value.migrating else { throw CredentialProtectionError.busy }
            value.operations += 1
        }
        defer { state.withLock { $0.operations -= 1 } }
        return try body()
    }

    static func migration<T>(_ body: () throws -> T) throws -> T {
        try state.withLock { value in
            guard !value.migrating, value.operations == 0 else { throw CredentialProtectionError.busy }
            value.migrating = true
        }
        defer { state.withLock { $0.migrating = false } }
        return try body()
    }
}

public enum CredentialProtection {
    public static let service = ApplicationIdentity.bundleIdentifier
    private static var preferences: UserDefaults {
        UserDefaults(suiteName: ApplicationIdentity.credentialMetadataSuite)!
    }
    public static var isEnabled: Bool { preferences.bool(forKey: "userPresenceEnabled") }
    private static let metadataLock = Mutex(())
    static func isProtected(_ slot: UUID) -> Bool {
        preferences.stringArray(forKey: "protectedSlots")?.contains(slot.uuidString) == true
    }
    static func mark(_ slot: UUID, protected: Bool) {
        metadataLock.withLock { _ in
            var slots = Set(preferences.stringArray(forKey: "protectedSlots") ?? [])
            if protected { slots.insert(slot.uuidString) } else { slots.remove(slot.uuidString) }
            preferences.set(slots.sorted(), forKey: "protectedSlots")
        }
    }

    /// Entitlements are meaningful only with a non-ad-hoc signature. Do not
    /// advertise biometrics for a plain `swift run` executable or fake identity.
    public static let hasSignedKeychainIdentity: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let identifier = entitlements["com.apple.application-identifier"] as? String,
              identifier.hasPrefix(team + "."),
              let groups = entitlements["keychain-access-groups"] as? [String],
              groups.contains(team + ".retroTools.MacSCP.credentials") else { return false }
        return true
    }()

    public static var hasEnrolledBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public static func enable() throws -> Int {
        guard hasSignedKeychainIdentity else { throw CredentialProtectionError.signatureRequired }
        guard hasEnrolledBiometrics else { throw CredentialProtectionError.biometricsUnavailable }
        return try CredentialAccessGate.migration {
            let legacy = KeychainItemStore(service: SharedCredentialVault.service, usesDataProtection: false,
                authentication: SharedVaultKeychain.authentication)
            let protected = KeychainItemStore(service: SharedCredentialVault.service, usesDataProtection: true,
                authentication: SharedVaultKeychain.authentication)
            // Probe actual Keychain permissions and authentication before touching
            // existing data. Entitlement inspection alone is not proof of access.
            let probe = UUID()
            let value = UUID().uuidString
            defer { try? protected.deletePassword(for: probe) }
            try protected.savePassword(value, for: probe)
            guard try protected.password(for: probe) == value else {
                throw CredentialProtectionError.verificationFailed
            }
            let count = try CredentialMigration.migrate(slots: legacy.slots(), from: legacy, to: protected,
                didVerify: { mark($0, protected: true) })
            preferences.set(true, forKey: "userPresenceEnabled")
            return count
        }
    }

    /// Explicit, authenticated return to the standard store. A cancellation
    /// leaves protected originals in place and can be retried.
    public static func disable() throws -> Int {
        guard hasSignedKeychainIdentity else { throw CredentialProtectionError.signatureRequired }
        return try CredentialAccessGate.migration {
            let legacy = KeychainItemStore(service: SharedCredentialVault.service, usesDataProtection: false,
                authentication: SharedVaultKeychain.authentication)
            let protected = KeychainItemStore(service: SharedCredentialVault.service, usesDataProtection: true,
                authentication: SharedVaultKeychain.authentication)
            let count = try CredentialMigration.migrate(slots: protected.slots(), from: protected, to: legacy,
                didMigrate: { mark($0, protected: false) })
            preferences.set(false, forKey: "userPresenceEnabled")
            return count
        }
    }

}

/// Only this adapter knows Security.framework dictionaries. Protected items
/// use the Data Protection Keychain, a real user-presence ACL and no sync.
struct KeychainItemStore: SecretStore {
    let service: String
    let usesDataProtection: Bool
    var authentication: VaultAuthentication? = nil
    var allowsAuthenticationUI: Bool = true

    func query(for slot: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        if let slot { query[kSecAttrAccount as String] = slot.uuidString }
        if usesDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        if let authentication {
            authentication.context.interactionNotAllowed = !allowsAuthenticationUI
            query[kSecUseAuthenticationContext as String] = authentication.context
        }
        return query
    }

    func password(for sessionID: UUID) throws -> String? {
        var query = query(for: sessionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if usesDataProtection && authentication == nil {
            let context = LAContext()
            context.localizedReason = CoreL10n.string("core.credentials.unlockReason")
            context.touchIDAuthenticationAllowableReuseDuration = 30
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return value
    }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        var values: [String: Any] = [kSecValueData as String: Data(password.utf8),
                                    kSecAttrLabel as String: CoreL10n.string("core.credentials.label")]
        if usesDataProtection {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
                if let error { throw error.takeRetainedValue() }
                throw CredentialProtectionError.verificationFailed
            }
            values[kSecAttrAccessControl as String] = access
        }
        let status = SecItemUpdate(query(for: sessionID) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: sessionID)
            item.merge(values) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func deletePassword(for sessionID: UUID) throws {
        let status = SecItemDelete(query(for: sessionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func slots() throws -> [UUID] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let entries = result as? [[String: Any]] else { throw KeychainError(status: status) }
        return try entries.map {
            guard let account = $0[kSecAttrAccount as String] as? String, let id = UUID(uuidString: account) else {
                throw CredentialProtectionError.verificationFailed
            }
            return id
        }
    }

}
