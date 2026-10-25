import Foundation
import Testing
@testable import macSCPCore

@Suite("Session appearance persistence")
@MainActor
struct SessionAppearanceTests {
    @Test(arguments: SessionAppearance.Icon.allCases)
    func everyRoleSurvivesNativeEncoding(icon: SessionAppearance.Icon) throws {
        let appearance = SessionAppearance(icon: icon, tint: .teal)
        #expect(try JSONDecoder().decode(SessionAppearance.self,
            from: JSONEncoder().encode(appearance)) == appearance)
    }

    @Test(arguments: ["web", "desktop", "laptop", "vmwareESXi"])
    func existingDeviceRolesKeepTheirStoredIdentifiers(identifier: String) throws {
        let encoded = Data("\"\(identifier)\"".utf8)
        let icon = try JSONDecoder().decode(SessionAppearance.Icon.self, from: encoded)
        #expect(icon.rawValue == identifier)
        #expect(try JSONEncoder().encode(icon) == encoded)
    }

    @Test func oldSessionsAndUnknownCatalogueValuesUseSafeDefaults() throws {
        let raw = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"legacy\"}".utf8)
        #expect(try JSONDecoder().decode(StoredSession.self, from: raw).appearance == nil)
        let newer = Data("{\"icon\":\"future-role\",\"tint\":\"future-color\"}".utf8)
        #expect(try JSONDecoder().decode(SessionAppearance.self, from: newer) == SessionAppearance())
    }

    @Test func editingAndDuplicationPreserveAppearanceAndNewDraftsResetIt() throws {
        let appearance = SessionAppearance(icon: .database, tint: .purple)
        let session = StoredSession(name: "Database", ssh: .init(host: "db.example", username: "operator"),
                                    appearance: appearance)
        #expect(SessionDuplication.copy(of: session, avoiding: [session]).appearance == appearance)
        let form = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
        form.beginEditing(session)
        #expect(form.appearance == appearance)
        form.appearance = .init(icon: .bastion, tint: .teal)
        #expect(try #require(form.validateForEditSave()).appearance == form.appearance)
        form.endEditing()
        #expect(form.appearance == SessionAppearance())
        form.beginEditing(session)
        form.exitEditMode()
        #expect(form.appearance == SessionAppearance())
    }

    @Test func saveStoreAndNativeExportImportPreserveAppearance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func model(_ directory: URL) -> SessionListViewModel {
            SessionListViewModel(store: SessionStore(directory: directory), secrets: InMemorySecretStore(),
                auditStore: AuditLogStore(directory: directory), loginSetStore: LoginSetStore(directory: directory),
                keys: ManagedKeyStore(directory: directory))
        }
        let source = model(directory)
        let record = StoredSession(name: "AI", ssh: .init(host: "ai.example", username: "operator"))
        let appearance = SessionAppearance(icon: .ai, tint: .orange, applicationLogo: "redis")
        let saved = try #require(source.save(name: record.name,
            values: BackendDescriptor.descriptor(for: .ssh).sessionValues(record), password: "", appearance: appearance))
        #expect(saved.appearance == appearance)
        #expect(try SessionStore(directory: directory).all().first?.appearance == appearance)
        let (payload, _) = source.exportPayload(for: .single(saved), includeGroups: false, includePasswords: false)
        let decoded = try JSONDecoder().decode(SessionExportPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.sessions.first?.appearance == appearance)
        let plan = await SessionImportPlanner.plan(existing: [], existingGroups: [], incoming: decoded,
            arbiter: ImportConflictArbiter { _ in
                Issue.record("Fresh import must not require conflict resolution")
                return nil
            })
        let target = model(directory.appendingPathComponent("target"))
        #expect(target.applyImport(plan).imported == 1)
        #expect(target.sessions.first?.appearance == appearance)
    }
}
