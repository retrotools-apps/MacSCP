import Foundation
import Testing
@testable import macSCPCore

struct HostKeyReviewWorkflowTests {
    @Test func explicitReplacementIsOneAtomicUpdateScopedToTheCapturedEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        let old = KnownHostKey(host: "fixture.invalid", port: 2222, keyType: "ssh-ed25519",
            publicKeyBase64: Data("synthetic old public blob".utf8).base64EncodedString())
        let other = KnownHostKey(host: old.host, port: 22, keyType: old.keyType, publicKeyBase64: old.publicKeyBase64)
        let candidate = HostKeyCandidate(host: old.host, port: old.port, keyType: old.keyType,
            publicKeyBase64: Data("synthetic new public blob".utf8).base64EncodedString())
        let change = HostKeyMismatchDetails(host: old.host, expected: old.fingerprintSHA256,
            presented: candidate.fingerprintSHA256, candidate: candidate)
        try store.upsert(old)
        try store.upsert(other)
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: old) == .mismatch(expected: old.fingerprintSHA256))
        #expect(try store.find(host: old.host, port: old.port) == old)
        #expect(try store.replaceChangedKey(change))
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: try store.find(host: old.host, port: old.port)) == .accept)
        #expect(try store.find(host: other.host, port: other.port) == other)
        #expect(try !store.replaceChangedKey(change))
        let wrong = HostKeyCandidate(host: "other.invalid", port: 22, keyType: old.keyType, publicKeyBase64: old.publicKeyBase64)
        #expect(try !store.replaceChangedKey(.init(host: old.host, expected: change.expected, presented: wrong.fingerprintSHA256, candidate: wrong)))
        #expect(try !store.replaceChangedKey(.init(host: old.host, expected: change.expected, presented: change.presented)))
    }

    @MainActor @Test func successfulReplacementIsRecordedEvenWithDetailedLoggingOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        let old = KnownHostKey(host: "jump.invalid", port: 2222, keyType: "ssh-ed25519",
            publicKeyBase64: Data("synthetic audit old key".utf8).base64EncodedString())
        let candidate = HostKeyCandidate(host: old.host, port: old.port, keyType: old.keyType,
            publicKeyBase64: Data("synthetic audit new key".utf8).base64EncodedString())
        try store.upsert(old)
        let audit = AuditLogStore(directory: directory.appendingPathComponent("audit"), isLoggingEnabled: { false })
        let vm = ConnectionViewModel(connector: { _, _ in
            throw HostKeyError.mismatch(host: old.host, expected: old.fingerprintSHA256,
                                       presented: candidate.fingerprintSHA256, candidate: candidate)
        })
        vm.host = "target.invalid"; vm.username = "fixture"; vm.password = "synthetic fixture credential"
        let sessionID = UUID()
        _ = await vm.connect(origin: sessionID)
        #expect(try vm.replaceChangedHostKey(in: store, auditStore: audit))
        let events = audit.events(for: sessionID)
        #expect(events.count == 1)
        #expect(events.first?.kind == .hostKeyReplaced)
        #expect(events.first?.detail.contains(old.fingerprintSHA256) == true)
        #expect(events.first?.detail.contains(candidate.fingerprintSHA256) == true)
        #expect(events.first?.detail.contains("host=jump.invalid port=2222") == true)
        #expect(ConnectionHistory.rows(from: events).first?.outcome == .hostKeyReplaced)
        #expect(try !vm.replaceChangedHostKey(in: store, auditStore: audit))
        #expect(audit.events(for: sessionID).count == 1)
    }

    private actor FailingConnector {
        var calls = 0
        func connect() throws -> any RemoteFileSystem {
            calls += 1
            if calls == 1 {
                let candidate = HostKeyCandidate(host: "jump.invalid", port: 2222, keyType: "ssh-ed25519",
                    publicKeyBase64: Data("synthetic candidate blob".utf8).base64EncodedString())
                throw HostKeyError.mismatch(host: candidate.host, expected: "SHA256:synthetic-old",
                    presented: candidate.fingerprintSHA256, candidate: candidate)
            }
            throw HostKeyError.rejectedByUser
        }
    }

    @MainActor @Test func mismatchEvidenceNamesTheActualHopAndDoesNotSurviveAnotherAttempt() async {
        let connector = FailingConnector()
        let vm = ConnectionViewModel(connector: { _, _ in try await connector.connect() })
        vm.host = "target.invalid"
        vm.username = "fixture"
        vm.password = "synthetic fixture credential"
        _ = await vm.connect()
        #expect(vm.lastHostKeyMismatch?.host == "jump.invalid")
        #expect(vm.lastHostKeyMismatch?.candidate?.port == 2222)
        #expect(vm.lastFailureKind == .needsPerson)
        _ = await vm.connect()
        #expect(vm.lastHostKeyMismatch == nil)
    }
}
