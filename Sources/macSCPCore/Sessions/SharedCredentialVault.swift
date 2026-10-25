import Foundation
import Darwin
import LocalAuthentication
import Synchronization

public enum SharedVaultError: Error, LocalizedError, Sendable, Equatable {
    case locked, unsupportedVersion, alreadyOpen
    public var errorDescription: String? {
        switch self {
        case .locked: CoreL10n.string("core.vault.locked")
        case .unsupportedVersion: CoreL10n.string("core.vault.unsupported")
        case .alreadyOpen: CoreL10n.string("core.vault.alreadyOpen")
        }
    }
}

protocol SharedVaultPersistence: Sendable {
    func readAtLaunch() throws -> String?
    func write(_ value: String) throws
    func close()
}

extension SharedVaultPersistence { func close() {} }

/// One process-wide credential vault, not session/window state. Session reads
/// use memory; a failed unlock is retried only on an explicit user action.
/// No mutex is held while an authentication dialog can be visible.
public final class SharedCredentialVault: SecretStore, SecretPresence, Sendable {
    public static let shared = SharedCredentialVault(persistence: SharedVaultKeychain())
    static let service = ApplicationIdentity.bundleIdentifier + ".vault"
    static let slot = UUID(uuidString: "BAF5038D-18C5-4A11-9BD9-177851A81A57")!
    private struct Envelope: Codable { let version: Int; var secrets: [String: String] }
    private enum State { case locked, opening, ready([UUID: String]), writing([UUID: String]), failed(any Error), closing, closed }
    private let state = Mutex<State>(.locked)
    private let persistence: any SharedVaultPersistence

    init(persistence: any SharedVaultPersistence) { self.persistence = persistence }

    public func unlockAtLaunch() throws {
        let shouldRead = try state.withLock { value -> Bool in
            switch value {
            case .locked: value = .opening; return true
            case .ready: return false
            case .failed(let error): throw error
            case .opening, .writing: throw CredentialProtectionError.busy
            case .closing, .closed: throw SharedVaultError.locked
            }
        }
        guard shouldRead else { return }
        do {
            let stored = try persistence.readAtLaunch()
            var entries: [UUID: String] = [:]
            if let stored {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(stored.utf8))
                guard envelope.version == 1 else { throw SharedVaultError.unsupportedVersion }
                for (key, value) in envelope.secrets {
                    guard let id = UUID(uuidString: key) else { throw SharedVaultError.unsupportedVersion }
                    entries[id] = value
                }
            }
            try state.withLock { state in
                guard case .opening = state else { throw SharedVaultError.locked }
                state = .ready(entries)
            }
        } catch {
            state.withLock { state in
                switch state {
                case .opening: state = .failed(error)
                case .closing: state = .closed
                default: break
                }
            }
            persistence.close()
            throw error
        }
    }

    public func retryUnlockAtUserRequest() throws {
        state.withLock { state in if case .failed = state { state = .locked } }
        try unlockAtLaunch()
    }

    public func password(for sessionID: UUID) throws -> String? {
        try state.withLock { state in
            switch state {
            case .ready(let values), .writing(let values): return values[sessionID]
            default: throw SharedVaultError.locked
            }
        }
    }

    public func hasSecret(for slot: UUID) -> Bool {
        state.withLock { state in
            switch state {
            case .ready(let values), .writing(let values): return values[slot] != nil
            default: return false
            }
        }
    }

    public func savePassword(_ password: String, for sessionID: UUID) throws {
        try change { $0[sessionID] = password }
    }

    public func deletePassword(for sessionID: UUID) throws {
        try change { $0.removeValue(forKey: sessionID) }
    }

    private func change(_ mutation: (inout [UUID: String]) -> Void) throws {
        let previous = try state.withLock { state -> [UUID: String] in
            if case .writing = state { throw CredentialProtectionError.busy }
            guard case .ready(let values) = state else { throw SharedVaultError.locked }
            state = .writing(values)
            return values
        }
        do {
            var values = previous
            mutation(&values)
            if values == previous {
                let closed = state.withLock { state in
                    if case .closing = state { state = .closed; return true }
                    state = .ready(previous)
                    return false
                }
                if closed { persistence.close() }
                return
            }
            let envelope = Envelope(version: 1, secrets: Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) }))
            let encoded = try JSONEncoder().encode(envelope)
            // Authorization is allowed for an explicit write. No lock is held
            // over that dialog; readers see the last committed snapshot.
            try persistence.write(String(decoding: encoded, as: UTF8.self))
            let closed = state.withLock { state in
                if case .closing = state { state = .closed; return true }
                state = .ready(values)
                return false
            }
            if closed { persistence.close() }
        } catch {
            let closed = state.withLock { state in
                if case .closing = state { state = .closed; return true }
                state = .ready(previous)
                return false
            }
            if closed { persistence.close() }
            throw error
        }
    }

    public func close() {
        let shouldClose = state.withLock { state in
            let busy: Bool
            switch state { case .opening, .writing, .closing: busy = true; default: busy = false }
            state = busy ? .closing : .closed
            return !busy
        }
        if shouldClose { persistence.close() }
    }

    /// Exact former per-session service only; never read secret data, never
    /// touch the common vault, another app's service or private-key files.
    public static func deleteOldEntries() throws -> Int {
        try CredentialAccessGate.migration {
            var count = 0
            let variants = CredentialProtection.hasSignedKeychainIdentity ? [false, true] : [false]
            for protected in variants {
                let store = KeychainItemStore(service: ApplicationIdentity.bundleIdentifier,
                    usesDataProtection: protected, authentication: SharedVaultKeychain.authentication,
                    allowsAuthenticationUI: true)
                for slot in try store.slots() {
                    try store.deletePassword(for: slot)
                    CredentialProtection.mark(slot, protected: false)
                    count += 1
                }
            }
            return count
        }
    }
}

/// LAContext is accessed only by the serialized vault or the exclusive
/// credential-protection operation, never by concurrent session reads.
final class VaultAuthentication: @unchecked Sendable {
    let context = LAContext()
}

final class SharedVaultKeychain: SharedVaultPersistence, Sendable {
    static let authentication = VaultAuthentication()
    private let lease = VaultWriterLease()
    private func store(allowUI: Bool) throws -> KeychainItemStore {
        let protected = CredentialProtection.isEnabled || CredentialProtection.isProtected(SharedCredentialVault.slot)
        if protected && !CredentialProtection.hasSignedKeychainIdentity {
            throw CredentialProtectionError.signatureRequired
        }
        return KeychainItemStore(service: SharedCredentialVault.service, usesDataProtection: protected,
            authentication: Self.authentication, allowsAuthenticationUI: allowUI)
    }
    func readAtLaunch() throws -> String? {
        try lease.acquire(in: SessionStore.defaultDirectory)
        return try CredentialAccessGate.operation {
            try store(allowUI: true).password(for: SharedCredentialVault.slot)
        }
    }
    func write(_ value: String) throws {
        try CredentialAccessGate.operation {
            try store(allowUI: true).savePassword(value, for: SharedCredentialVault.slot)
        }
    }
    func close() { lease.close() }
}

/// Serializes whole-vault writes across processes without reading secrets
/// again. The lock file contains no credentials; the kernel releases it on crash.
/// Explicit close releases ownership even if a subprocess duplicated the descriptor.
final class VaultWriterLease: Sendable {
    private let descriptor = Mutex<Int32?>(nil)
    func acquire(in directory: URL) throws {
        try descriptor.withLock { descriptor in
            guard descriptor == nil else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("credentials-vault.lock").path
            let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd)
                throw SharedVaultError.alreadyOpen
            }
            descriptor = fd
        }
    }
    func close() {
        descriptor.withLock { descriptor in
            if let fd = descriptor {
                // Process creation can temporarily duplicate the descriptor,
                // even with O_CLOEXEC. Closing only our reference need not release
                // the flock until every duplicate closes. Relinquish ownership
                // explicitly before closing; retry only the interrupted unlock.
                while flock(fd, LOCK_UN) != 0 && errno == EINTR {}
                Darwin.close(fd)
            }
            descriptor = nil
        }
    }
}
