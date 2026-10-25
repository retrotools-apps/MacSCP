import Foundation
import MacSCPTestSupport
import Synchronization
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Login editor preserves unchanged credentials")
@MainActor
struct LoginSetEditorValidationTests {
    private func values(for set: LoginSet) -> FieldValues {
        let descriptor = BackendDescriptor.descriptor(for: set.kind)
        var values = descriptor.editBaseline
        values.merge(descriptor.loginSetValues(set))
        return values
    }

    @Test(arguments: ConnectionKind.allCases)
    func renameDoesNotRequireTheExistingSecret(kind: ConnectionKind) {
        let existing = LoginSet(name: "Original", username: "operator", kind: kind, accessKeyID: "fixture-access-id")
        #expect(LoginSetEditorValidation.canSave(name: "Renamed", kind: kind, values: values(for: existing), existing: existing))
        #expect(!LoginSetEditorValidation.canSave(name: " \n", kind: kind, values: values(for: existing), existing: existing))
    }

    @Test func newPasswordLoginsAndAuthenticationChangesStillRequireAPassword() {
        let password = LoginSet(name: "Original", username: "operator")
        var fields = values(for: password)
        #expect(!LoginSetEditorValidation.canSave(name: "New", kind: .ssh, values: fields, existing: nil))
        let agent = LoginSet(name: "Original", username: "operator", authKind: .agent)
        #expect(!LoginSetEditorValidation.canSave(name: "Changed", kind: .ssh, values: fields, existing: agent))
        fields[SSHField.password] = "fixture-only-replacement"
        #expect(LoginSetEditorValidation.canSave(name: "Changed", kind: .ssh, values: fields, existing: agent))
        fields[SSHField.username] = "  "
        #expect(!LoginSetEditorValidation.canSave(name: "Renamed", kind: .ssh, values: fields, existing: password))
    }

    @Test func protocolChangesDoNotReuseAnUnrelatedSecretForValidation() {
        let ssh = LoginSet(name: "Original", username: "operator")
        let s3 = LoginSet(name: "Object storage", username: "", kind: .s3, accessKeyID: "fixture-access-id")
        #expect(!LoginSetEditorValidation.canSave(name: "Changed", kind: .s3, values: values(for: s3), existing: ssh))
        #expect(!LoginSetEditorValidation.canSave(name: "New", kind: .s3, values: values(for: s3), existing: nil))
    }

    @Test func privateKeysStillRequireAPathAndAgentLoginsNeedNoSecret() {
        let key = LoginSet(name: "Key", username: "operator", authKind: .privateKey, keyPath: "/fixture/key")
        var fields = values(for: key)
        #expect(LoginSetEditorValidation.canSave(name: "Renamed", kind: .ssh, values: fields, existing: key))
        fields[SSHField.keyPath] = ""
        #expect(!LoginSetEditorValidation.canSave(name: "Renamed", kind: .ssh, values: fields, existing: key))
        let agent = LoginSet(name: "Agent", username: "operator", authKind: .agent)
        #expect(LoginSetEditorValidation.canSave(name: "Agent", kind: .ssh, values: values(for: agent), existing: nil))
    }

    private final class CountingSecrets: SecretStore, Sendable {
        private struct State {
            var values: [UUID: String] = [:]
            var writes = 0
            var deletes = 0
        }
        private let state = Mutex(State())
        var writes: Int { state.withLock { $0.writes } }
        var deletes: Int { state.withLock { $0.deletes } }
        func password(for id: UUID) throws -> String? { state.withLock { $0.values[id] } }
        func savePassword(_ password: String, for id: UUID) throws {
            state.withLock { $0.values[id] = password; $0.writes += 1 }
        }
        func deletePassword(for id: UUID) throws { state.withLock { $0.values[id] = nil; $0.deletes += 1 } }
    }

    @Test func savingARenameKeepsTheSameSecretSlotAndNeverRewritesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = CountingSecrets()
        let model = SessionListViewModel(store: SessionStore(directory: directory), secrets: secrets,
            auditStore: AuditLogStore(directory: directory), loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
        var set = LoginSet(name: "Original", username: "operator")
        let originalSecret = "fixture-existing-password"
        #expect(model.saveLoginSet(set, secret: originalSecret))
        let writesBefore = secrets.writes
        set.name = "Renamed"
        #expect(model.saveLoginSet(set, secret: nil))
        #expect(try LoginSetStore(directory: directory).all() == [set])
        let sameSecret = try secrets.password(for: set.id) == originalSecret
        #expect(sameSecret)
        #expect(secrets.writes == writesBefore)
        #expect(secrets.deletes == 0)
    }

    @Test func editorUsesTheValidationPlanAndSendsNilForUnchangedSecrets() throws {
        let source = try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/LoginSetsSheet.swift"))
        #expect(source.contains("LoginSetEditorValidation.canSave(name: name, kind: kind, values: values, existing: existing)"))
        #expect(source.contains("onSave(set, secret.isEmpty ? nil : secret)"))
    }
}
