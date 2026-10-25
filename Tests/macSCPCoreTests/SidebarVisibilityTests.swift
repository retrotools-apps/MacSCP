import Foundation
import Testing
@testable import macSCPCore

@Suite("Sidebar visibility")
struct SidebarVisibilityTests {
    private func session(_ name: String, groupID: UUID? = nil) -> StoredSession {
        StoredSession(
            name: name, groupID: groupID, kind: .ssh,
            ssh: StoredSSHConfig(host: "\(name).example", username: "deploy"))
    }

    private func search(_ text: String) -> FileSearch.FileSearchPredicate {
        try! FileSearch.compile(query: text, isRegex: false).get()
    }

    @Test func noSearchPreservesSessionsFoldersAndImportedSection() {
        let group = StoredGroup(name: "Production")
        let stored = session("web", groupID: group.id)
        let result = SidebarVisibility.compute(
            sessions: [stored], groups: [group], importedHostsCount: 2, search: nil)

        #expect(result.children(of: nil) == [.group(group.id)])
        #expect(result.children(of: group.id) == [.session(stored.id)])
        #expect(result.showsImportedSection)
        #expect(!result.expandsFolders)
        #expect(result.emptiness == .notEmpty)
    }

    @Test func searchMatchesNameAndBackendSummary() {
        let named = session("database")
        let hostMatch = StoredSession(
            name: "service", kind: .ssh,
            ssh: StoredSSHConfig(host: "production.example", username: "deploy"))

        let byName = SidebarVisibility.compute(
            sessions: [named, hostMatch], groups: [], importedHostsCount: 0,
            search: search("database"))
        let byHost = SidebarVisibility.compute(
            sessions: [named, hostMatch], groups: [], importedHostsCount: 0,
            search: search("production"))

        #expect(byName.children(of: nil) == [.session(named.id)])
        #expect(byHost.children(of: nil) == [.session(hostMatch.id)])
    }

    @Test func searchKeepsTheAncestorChainAndHidesImportedHosts() {
        let outer = StoredGroup(name: "Outer")
        let inner = StoredGroup(name: "Inner", parentID: outer.id)
        let match = session("web", groupID: inner.id)
        let result = SidebarVisibility.compute(
            sessions: [match], groups: [outer, inner], importedHostsCount: 4,
            search: search("web"))

        #expect(result.children(of: nil) == [.group(outer.id)])
        #expect(result.children(of: outer.id) == [.group(inner.id)])
        #expect(result.children(of: inner.id) == [.session(match.id)])
        #expect(!result.showsImportedSection)
        #expect(result.expandsFolders)
    }

    @Test func emptinessDistinguishesAnEmptyStoreFromNoSearchMatch() {
        let empty = SidebarVisibility.compute(
            sessions: [], groups: [], importedHostsCount: 0, search: nil)
        let noMatch = SidebarVisibility.compute(
            sessions: [session("web")], groups: [], importedHostsCount: 0,
            search: search("absent"))

        #expect(empty.emptiness == .noSessionsAtAll)
        #expect(noMatch.emptiness == .filterMatchesNothing)
    }
}
