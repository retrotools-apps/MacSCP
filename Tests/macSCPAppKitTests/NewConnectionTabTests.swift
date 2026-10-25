import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("New connection tab", .timeLimit(.minutes(1)))
@MainActor
struct NewConnectionTabTests {
    @Test func oneDraftIsReusedAndABackgroundGroupKeepsItsTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-new-tab-\(UUID().uuidString)")
        let settings = root.appendingPathComponent("settings")
        let sessions = root.appendingPathComponent("sessions")
        let audits = root.appendingPathComponent("audits")
        defer { try? FileManager.default.removeItem(at: root) }

        let secrets = NewTabSecretStore()
        let list = SessionListViewModel(
            store: SessionStore(directory: sessions), secrets: secrets,
            auditStore: AuditLogStore(directory: audits),
            loginSetStore: LoginSetStore(directory: sessions),
            keys: ManagedKeyStore(directory: sessions))
        let view = ContentView(
            settingsStore: SettingsStore(directory: settings),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: audits),
            tabCommands: TabCommands(), menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: list, secretStore: secrets,
            managedKeyStore: ManagedKeyStore(directory: sessions))

        view.newConnection()
        let draft = view.activeTab
        draft.connectionViewModel.host = "typed.example"
        view.showNewConnectionTab()
        #expect(view.tabsModel.tabs.count == 1)
        #expect(view.activeTab.id == draft.id)
        #expect(view.activeTab.connectionViewModel.host == "typed.example")

        let home = try #require(list.createGroup(named: "Home"))
        view.showSessionGroup(home)
        let homeTab = view.activeTab
        view.showNewConnectionTab()
        let blankTab = view.activeTab
        #expect(view.tabsModel.tabs.count == 2)
        #expect(blankTab.id != homeTab.id)

        view.showNewConnectionTab()
        #expect(view.tabsModel.tabs.count == 2)
        #expect(view.activeTab.id == blankTab.id)

        view.activate(homeTab.id)
        #expect(view.tabTitle(for: homeTab) == .named("Home"))
        view.activate(blankTab.id)
        #expect(view.tabTitle(for: homeTab) == .named("Home"))
    }
}

private final class NewTabSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
