import Foundation
import Security
import Synchronization
import Testing
@testable import macSCPCore

@Suite("Protected credential routing and migration", .serialized)
struct CredentialProtectionTests {
    private enum Failure: Error { case refused, write, remove }
    private final class Store: SecretStore, @unchecked Sendable {
        struct State {
            var values: [UUID: String] = [:]
            var reads = 0
            var writes = 0
            var readFailure = false
            var writeFailure = false
            var deleteFailure = false
            var corruptWrites = false
            var changeOnSecondRead = false
        }
        let state = Mutex(State())
        func password(for sessionID: UUID) throws -> String? {
            try state.withLock {
                $0.reads += 1
                if $0.readFailure { throw Failure.refused }
                if $0.changeOnSecondRead, $0.reads == 2 { $0.values[sessionID] = "changed-fixture" }
                return $0.values[sessionID]
            }
        }
        func savePassword(_ password: String, for sessionID: UUID) throws {
            try state.withLock {
                $0.writes += 1
                if $0.writeFailure { throw Failure.write }
                $0.values[sessionID] = $0.corruptWrites ? "corrupt-fixture" : password
            }
        }
        func deletePassword(for sessionID: UUID) throws {
            try state.withLock {
                if $0.deleteFailure { throw Failure.remove }
                $0.values.removeValue(forKey: sessionID)
            }
        }
    }

    @Test func authenticationRefusalNeverFallsBackToLegacy() throws {
        let id = UUID(), old = Store(), protected = Store()
        try old.savePassword("fixture", for: id)
        protected.state.withLock { $0.readFailure = true }
        let vault = CredentialVault(legacy: old, protected: protected,
                                   canUseProtectedStorage: true, preferProtectedStorage: false)
        #expect(throws: Failure.self) { try vault.password(for: id) }
        #expect(old.state.withLock { $0.reads } == 0)
    }

    @Test func aProtectedReadNeverUsesAnUnprotectedDuplicateEvenIfTheProtectedItemIsMissing() throws {
        let id = UUID(), old = Store(), protected = Store()
        try old.savePassword("fixture", for: id)
        let vault = CredentialVault(legacy: old, protected: protected,
                                   canUseProtectedStorage: true, preferProtectedStorage: true)
        #expect(try vault.password(for: id) == nil)
        #expect(old.state.withLock { $0.reads } == 0)
    }

    @Test func anUnsignedBuildCannotUseProtectedCredentials() throws {
        let id = UUID(), old = Store(), protected = Store()
        let vault = CredentialVault(legacy: old, protected: protected,
                                   canUseProtectedStorage: false, preferProtectedStorage: true)
        #expect(throws: CredentialProtectionError.self) { try vault.password(for: id) }
        let value = "fixture"
        #expect(throws: CredentialProtectionError.self) { try vault.savePassword(value, for: id) }
        #expect(old.state.withLock { $0.reads + $0.writes } == 0)
    }

    @Test func protectionWritesNeverDowngradeToTheLegacyStore() throws {
        let id = UUID(), old = Store(), protected = Store()
        let vault = CredentialVault(legacy: old, protected: protected,
                                   canUseProtectedStorage: true, preferProtectedStorage: true)
        try vault.savePassword("fixture", for: id)
        #expect(old.state.withLock { $0.writes } == 0)
        #expect(protected.state.withLock { $0.writes } == 1)
    }

    @Test func partialMigrationRemainsProtectedEvenBeforeTheGlobalPreferenceIsEnabled() throws {
        let id = UUID(), old = Store(), protected = Store()
        try protected.savePassword("fixture", for: id)
        let vault = CredentialVault(legacy: old, protected: protected,
                                   canUseProtectedStorage: true, preferProtectedStorage: false)
        try vault.savePassword("replacement-fixture", for: id)
        #expect(old.state.withLock { $0.writes } == 0)
        #expect(protected.state.withLock { $0.writes } == 2)
    }

    @Test(arguments: ["write", "read", "corrupt", "sourceChanged", "delete"])
    func migrationNeverRemovesAnUnverifiedSource(fault: String) throws {
        let id = UUID(), old = Store(), protected = Store()
        let original = "fixture"
        try old.savePassword(original, for: id)
        protected.state.withLock {
            $0.writeFailure = fault == "write"
            $0.readFailure = fault == "read"
            $0.corruptWrites = fault == "corrupt"
        }
        old.state.withLock {
            $0.changeOnSecondRead = fault == "sourceChanged"
            $0.deleteFailure = fault == "delete"
        }
        #expect(throws: (any Error).self) { try CredentialMigration.migrate(slots: [id], from: old, to: protected) }
        #expect(old.state.withLock { $0.values[id] != nil })
    }

    @Test func successfulMigrationVerifiesBeforeDeletingAndCanResume() throws {
        let id = UUID(), old = Store(), protected = Store()
        let original = "fixture"
        try old.savePassword(original, for: id)
        old.state.withLock { $0.deleteFailure = true }
        #expect(throws: Failure.self) { try CredentialMigration.migrate(slots: [id], from: old, to: protected) }
        let preserved = protected.state.withLock { $0.values[id] == original }
        #expect(preserved)
        old.state.withLock { $0.deleteFailure = false }
        #expect(try CredentialMigration.migrate(slots: [id], from: old, to: protected) == 1)
        #expect(old.state.withLock { $0.values.isEmpty })
        let verified = protected.state.withLock { $0.values[id] == original }
        #expect(verified)
    }

    @Test func migrationRefusesConcurrentCredentialOperationsWithoutWaiting() throws {
        _ = try CredentialAccessGate.operation {
            #expect(throws: CredentialProtectionError.self) { try CredentialAccessGate.migration {} }
        }
        _ = try CredentialAccessGate.migration {
            #expect(throws: CredentialProtectionError.self) { try CredentialAccessGate.operation {} }
            #expect(throws: CredentialProtectionError.self) { try CredentialAccessGate.migration {} }
        }
        #expect(throws: Never.self) { try CredentialAccessGate.operation {} }
    }

    @Test func retryNeverOverwritesADifferentDestinationCredential() throws {
        let id = UUID(), old = Store(), protected = Store()
        let original = "original-fixture", newer = "newer-fixture"
        try old.savePassword(original, for: id)
        try protected.savePassword(newer, for: id)
        #expect(throws: CredentialProtectionError.self) {
            try CredentialMigration.migrate(slots: [id], from: old, to: protected)
        }
        let oldIntact = old.state.withLock { $0.values[id] == original }
        let newIntact = protected.state.withLock { $0.values[id] == newer }
        #expect(oldIntact)
        #expect(newIntact)
        #expect(protected.state.withLock { $0.writes } == 1)
    }

    @Test func protectedQueriesOptIntoDataProtectionButKeepTheStableServiceAndAccount() {
        let id = UUID()
        let protected = KeychainItemStore(service: CredentialProtection.service, usesDataProtection: true).query(for: id)
        let legacy = KeychainItemStore(service: CredentialProtection.service, usesDataProtection: false).query(for: id)
        #expect(protected[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(protected[kSecAttrAccount as String] as? String == id.uuidString)
        #expect(protected[kSecAttrService as String] as? String == CredentialProtection.service)
    }

    @Test func unsignedActivationFailsBeforeReadingAnyKeychainItem() {
        guard !CredentialProtection.hasSignedKeychainIdentity else { return }
        #expect(throws: CredentialProtectionError.self) { try CredentialProtection.enable() }
    }
}
