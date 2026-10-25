import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing
@testable import macSCPCore

@Suite("One launch-unlocked credential vault")
struct SharedCredentialVaultTests {
    enum Failure: Error { case refused, write }
    final class Persistence: SharedVaultPersistence, Sendable {
        struct State {
            var stored: String?
            var reads = 0, writes = 0, closes = 0
            var refuseRead = false, refuseWrite = false
        }
        let state = Mutex(State())
        let beforeWrite = Mutex<(@Sendable () -> Void)?>(nil)
        func readAtLaunch() throws -> String? {
            try state.withLock {
                $0.reads += 1
                if $0.refuseRead { throw Failure.refused }
                return $0.stored
            }
        }
        func write(_ value: String) throws {
            beforeWrite.withLock { $0 }?()
            try state.withLock {
                $0.writes += 1
                if $0.refuseWrite { throw Failure.write }
                $0.stored = value
            }
        }
        func close() { state.withLock { $0.closes += 1 } }
    }

    @Test func everySessionUsesOneLaunchReadAndOnePersistedEnvelope() throws {
        let disk = Persistence(), first = UUID(), second = UUID()
        let vault = SharedCredentialVault(persistence: disk)
        try vault.unlockAtLaunch()
        try vault.savePassword("target-fixture", for: first)
        try vault.savePassword("jump-fixture", for: second)
        for _ in 0..<5 {
            try vault.unlockAtLaunch()
            let correct = try vault.password(for: first) == "target-fixture"
                && vault.password(for: second) == "jump-fixture"
            #expect(correct)
            #expect(vault.hasSecret(for: first) && vault.hasSecret(for: second))
        }
        #expect(disk.state.withLock { $0.reads } == 1)
        #expect(disk.state.withLock { $0.writes } == 2)
        let reopened = SharedCredentialVault(persistence: disk)
        try reopened.unlockAtLaunch()
        let recovered = try reopened.password(for: first) == "target-fixture"
            && reopened.password(for: second) == "jump-fixture"
        #expect(recovered)
        try reopened.deletePassword(for: first)
        #expect(!reopened.hasSecret(for: first))
        #expect(reopened.hasSecret(for: second))
        let third = SharedCredentialVault(persistence: disk)
        try third.unlockAtLaunch()
        let onlySurvivor = try third.password(for: first) == nil && third.password(for: second) == "jump-fixture"
        #expect(onlySurvivor)
    }

    @Test func refusalIsNeverRetriedByAnySessionOrWrite() throws {
        let disk = Persistence()
        disk.state.withLock { $0.refuseRead = true }
        let vault = SharedCredentialVault(persistence: disk)
        let id = UUID(), value = "new-fixture"
        for _ in 0..<5 {
            #expect(throws: Failure.self) { try vault.unlockAtLaunch() }
            #expect(throws: SharedVaultError.self) { try vault.password(for: id) }
            #expect(throws: SharedVaultError.self) { try vault.savePassword(value, for: id) }
        }
        #expect(disk.state.withLock { $0.reads } == 1)
        #expect(disk.state.withLock { $0.writes } == 0)
    }

    @Test func aRefusedWritePreservesCommittedSecretsAndCanBeRetried() throws {
        let disk = Persistence(), id = UUID(), added = UUID()
        let vault = SharedCredentialVault(persistence: disk)
        try vault.unlockAtLaunch()
        try vault.savePassword("old-fixture", for: id)
        let committed = disk.state.withLock { $0.stored }
        disk.state.withLock { $0.refuseWrite = true }
        let replacement = "new-fixture"
        #expect(throws: Failure.self) { try vault.savePassword(replacement, for: id) }
        #expect(throws: Failure.self) { try vault.savePassword(replacement, for: added) }
        #expect(throws: Failure.self) { try vault.deletePassword(for: id) }
        let preserved = try vault.password(for: id) == "old-fixture"
            && disk.state.withLock { $0.stored == committed }
        #expect(preserved)
        #expect(!vault.hasSecret(for: added))
        disk.state.withLock { $0.refuseWrite = false }
        try vault.savePassword(replacement, for: added)
        let saved = try vault.password(for: added) == replacement
        #expect(saved)
        #expect(disk.state.withLock { $0.reads } == 1)
    }

    @Test func anExplicitAuthorizationRetryCanRecoverWithoutRestarting() throws {
        let disk = Persistence(), vault = SharedCredentialVault(persistence: disk)
        disk.state.withLock { $0.refuseRead = true }
        #expect(throws: Failure.self) { try vault.unlockAtLaunch() }
        disk.state.withLock { $0.refuseRead = false }
        try vault.retryUnlockAtUserRequest()
        let value = "fixture", id = UUID()
        try vault.savePassword(value, for: id)
        let saved = try vault.password(for: id) == value
        #expect(saved)
        #expect(disk.state.withLock { $0.reads } == 2)
    }

    @Test func aWriteDialogHoldsNoStateLockAndDoesNotPublishUncommittedSecrets() throws {
        let disk = Persistence(), vault = SharedCredentialVault(persistence: disk), id = UUID()
        try vault.unlockAtLaunch()
        try vault.savePassword("old-fixture", for: id)
        let observedCommitted = Mutex(false)
        disk.beforeWrite.withLock { callback in
            callback = {
                let old = (try? vault.password(for: id)) == "old-fixture"
                observedCommitted.withLock { $0 = old }
                #expect(vault.hasSecret(for: id))
                let otherValue = "concurrent-fixture"
                #expect(throws: CredentialProtectionError.busy) { try vault.savePassword(otherValue, for: UUID()) }
            }
        }
        try vault.savePassword("new-fixture", for: id)
        disk.beforeWrite.withLock { $0 = nil }
        #expect(observedCommitted.withLock { $0 })
        let committed = try vault.password(for: id) == "new-fixture"
        #expect(committed)
    }

    @Test func repeatedQuitDuringAWriteKeepsOwnershipUntilTheWriteCompletes() throws {
        let disk = Persistence(), vault = SharedCredentialVault(persistence: disk), id = UUID()
        try vault.unlockAtLaunch()
        disk.beforeWrite.withLock { callback in
            callback = {
                vault.close()
                vault.close()
                #expect(disk.state.withLock { $0.closes } == 0)
            }
        }
        try vault.savePassword("fixture", for: id)
        disk.beforeWrite.withLock { $0 = nil }
        #expect(disk.state.withLock { $0.closes } == 1)
        #expect(!vault.hasSecret(for: id))
    }

    @Test func closingClearsMemoryAndCannotReauthorizeInTheSameProcess() throws {
        let disk = Persistence(), id = UUID(), value = "fixture"
        let vault = SharedCredentialVault(persistence: disk)
        try vault.unlockAtLaunch()
        try vault.savePassword(value, for: id)
        vault.close()
        #expect(!vault.hasSecret(for: id))
        #expect(throws: SharedVaultError.self) { try vault.password(for: id) }
        #expect(throws: SharedVaultError.self) { try vault.unlockAtLaunch() }
        #expect(disk.state.withLock { $0.reads } == 1)
    }

    @Test(arguments: ["not-json", "{\"version\":2,\"secrets\":{}}", "{\"version\":1,\"secrets\":{\"invalid-id\":\"fixture\"}}"])
    func malformedStorageIsNeverOverwritten(stored: String) {
        let disk = Persistence()
        disk.state.withLock { $0.stored = stored }
        let vault = SharedCredentialVault(persistence: disk), value = "fixture"
        #expect(throws: (any Error).self) { try vault.unlockAtLaunch() }
        #expect(throws: SharedVaultError.self) { try vault.savePassword(value, for: UUID()) }
        #expect(disk.state.withLock { $0.writes } == 0)
    }

    @Test func unchangedCredentialsAndMissingDeletesDoNotWrite() throws {
        let disk = Persistence(), id = UUID(), value = "fixture"
        let vault = SharedCredentialVault(persistence: disk)
        try vault.unlockAtLaunch()
        try vault.deletePassword(for: id)
        #expect(disk.state.withLock { $0.writes } == 0)
        try vault.savePassword(value, for: id)
        try vault.savePassword(value, for: id)
        #expect(disk.state.withLock { $0.writes } == 1)
    }

    @Test func anotherInstanceCannotOverwriteTheUnlockedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-lock-\(UUID())")
        let first = VaultWriterLease(), second = VaultWriterLease()
        defer { first.close(); second.close(); try? FileManager.default.removeItem(at: directory) }
        try first.acquire(in: directory)
        #expect(throws: SharedVaultError.alreadyOpen) { try second.acquire(in: directory) }
        first.close()
        try second.acquire(in: directory)
    }

    @Test func closingAnOldLeaseCannotUnlockItsSuccessor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-handoff-\(UUID())")
        let first = VaultWriterLease(), second = VaultWriterLease(), contender = VaultWriterLease()
        defer { first.close(); second.close(); contender.close(); try? FileManager.default.removeItem(at: directory) }
        try first.acquire(in: directory)
        first.close()
        try second.acquire(in: directory)
        first.close()
        #expect(throws: SharedVaultError.alreadyOpen) { try contender.acquire(in: directory) }
        second.close()
        try contender.acquire(in: directory)
    }

    @Test func writeAuthorizationUsesTheExistingAuthenticationContext() throws {
        let authentication = VaultAuthentication()
        let store = KeychainItemStore(service: SharedCredentialVault.service,
            usesDataProtection: false, authentication: authentication, allowsAuthenticationUI: true)
        let query = store.query(for: SharedCredentialVault.slot)
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context === authentication.context)
        #expect(!context.interactionNotAllowed)
        #expect(query[kSecAttrService as String] as? String == SharedCredentialVault.service)
        #expect(SharedCredentialVault.service != ApplicationIdentity.bundleIdentifier)
    }
}
