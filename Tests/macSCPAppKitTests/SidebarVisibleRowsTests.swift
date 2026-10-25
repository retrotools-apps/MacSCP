import AppKit
import MacSCPTestSupport
import Observation
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Sidebar disclosure row identities")
@MainActor
struct SidebarVisibleRowsTests {
    @Test func manualCollapsePreservesDescendantDisclosureChoicesInBothTrees() {
        let root = StoredGroup(name: "Root")
        let child = StoredGroup(name: "Child", parentID: root.id)
        let groups = [root, child]
        let leaf = StoredSession(name: "Leaf", groupID: child.id)
        let tree = visibility(groups, [leaf])
        var collapsed = Set(groups.map(\.id))
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed).map(\.id) == [root.id])
        collapsed.remove(root.id)
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed).map(\.id) == [root.id, child.id])
        collapsed.removeAll()
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed).map(\.id) == [root.id, child.id, leaf.id])

        let tunnelRoot = TunnelGroup(name: "Root")
        let tunnelChild = TunnelGroup(name: "Child", parentID: tunnelRoot.id)
        let tunnelGroups = [tunnelRoot, tunnelChild]
        let profile = TunnelProfile(sessionID: UUID(), name: "Leaf",
            kind: .dynamic(bind: "127.0.0.1", localPort: 19080), groupID: tunnelChild.id)
        collapsed = Set(tunnelGroups.map(\.id))
        #expect(TunnelCatalog.sidebarRows(groups: tunnelGroups, profiles: [profile], collapsed: collapsed).map(\.id) == [tunnelRoot.id])
        collapsed.remove(tunnelRoot.id)
        #expect(TunnelCatalog.sidebarRows(groups: tunnelGroups, profiles: [profile], collapsed: collapsed).map(\.id) == [tunnelRoot.id, tunnelChild.id])
        collapsed.removeAll()
        #expect(TunnelCatalog.sidebarRows(groups: tunnelGroups, profiles: [profile], collapsed: collapsed).map(\.id) == [tunnelRoot.id, tunnelChild.id, profile.id])
    }

    @Test func groupHeadersKeepACommonTrailingColumnAndBothToolbarsControlTheirOwnTree() throws {
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let sessions = try SourceCorpus.code(of: root.appendingPathComponent("SessionSidebar.swift"))
        let tunnels = try SourceCorpus.code(of: root.appendingPathComponent("TunnelWorkspaceSidebar.swift"))
        let toolbar = try SourceCorpus.commentFree(of: root.appendingPathComponent("SessionSidebarToolbar.swift"))
        for code in [sessions, tunnels] {
            #expect(code.contains("GroupColorControl(hue: group.colorHue, color: group.color,"))
            #expect(code.contains("onCollapseGroups:"))
            #expect(code.contains("onExpandGroups:"))
        }
        let sessionGroup = try #require(sessions.range(of: "case .group(let id):"))
        let sessionInsets = try #require(sessions.range(of: ".listRowInsets(", range: sessionGroup.upperBound..<sessions.endIndex))
        let groupLayout = String(sessions[sessionGroup.upperBound..<sessionInsets.lowerBound])
        #expect(groupLayout.contains("SidebarGroupHeader("))
        #expect(groupLayout.contains(".padding(.leading, SidebarIndentation.leading(depth: row.depth))"))
        #expect(!groupLayout.contains(".padding(.trailing"))
        let tunnelGroup = try #require(tunnels.range(of: "groupSection(row.group, depth: row.depth)"))
        let tunnelInsets = try #require(tunnels.range(of: ".listRowInsets(", range: tunnelGroup.upperBound..<tunnels.endIndex))
        #expect(!tunnels[tunnelGroup.upperBound..<tunnelInsets.lowerBound].contains(".padding(.trailing"))
        for code in [sessions, tunnels] {
            #expect(code.contains("groupsWithHiddenEntries.subtracting(parents)"))
            #expect(code.contains("groupsWithHiddenEntries.removeAll()"))
        }
        #expect(toolbar.contains("SidebarGroupActionIcon(action: .collapse)"))
        #expect(toolbar.contains("SidebarGroupActionIcon(action: .expand)"))
        #expect(toolbar.contains("Button(action: onCollapseGroups)"))
        #expect(toolbar.contains("Button(action: onExpandGroups)"))
        #expect(toolbar.contains(".disabled(!groupsAvailable || navigationDisabled)"))
    }

    @Test func bothWorkspacesUseTheSameNativeListSurface() throws {
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        for name in ["SessionSidebar.swift", "TunnelWorkspaceSidebar.swift"] {
            let code = try SourceCorpus.code(of: root.appendingPathComponent(name))
            #expect(code.contains("SidebarList {"))
        }
        let common = try SourceCorpus.code(of: root.appendingPathComponent("SidebarList.swift"))
        #expect(common.contains("List {"))
        #expect(common.contains("content()"))
        #expect(common.contains(".environment(\\.defaultMinListRowHeight, 24)"))
        #expect(common.contains(".listRowSeparator(.hidden)"))
    }

    @Test func ungroupedConnectionsPrecedeFoldersWithoutChangingStoredSiblingRanks() {
        let group = StoredGroup(name: "Production", position: 0)
        let loose = StoredSession(name: "Standalone", position: 10)
        let nested = StoredSession(name: "Web", groupID: group.id)
        let visibility = SidebarVisibility.compute(sessions: [loose, nested], groups: [group], importedHostsCount: 0,
                                                   search: nil)
        let rows = SidebarVisibleRows.build(under: nil, visibility: visibility, collapsed: [])
        #expect(rows.map(\.id) == [loose.id, group.id, nested.id])
        #expect(rows[1].startsSection)
    }

    private func visibility(_ groups: [StoredGroup], _ sessions: [StoredSession]) -> SidebarVisibility {
        SidebarVisibility.compute(sessions: sessions, groups: groups, importedHostsCount: 0,
                                  search: nil)
    }

    @Test func overviewKeepsTheWholeHierarchyAndUngroupedEntries() {
        let root = StoredGroup(name: "Root")
        let child = StoredGroup(name: "Child", parentID: root.id)
        let grandchild = StoredGroup(name: "Grandchild", parentID: child.id)
        let groups = [root, child, grandchild]
        let loose = StoredSession(name: "Loose")
        let direct = StoredSession(name: "Direct", groupID: root.id)
        let nested = StoredSession(name: "Nested", groupID: grandchild.id)
        let tree = visibility(groups, [loose, direct, nested])
        let hidden = Set(groups.map(\.id))
        let collapsed = hidden.subtracting(Set(groups.compactMap(\.parentID)))
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed,
                                        hiddenEntries: hidden).map(\.id) == [loose.id, root.id, child.id, grandchild.id])
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: [],
                                        hiddenEntries: hidden.subtracting([grandchild.id])).map(\.id)
                == [loose.id, root.id, child.id, grandchild.id, nested.id])
        let searching = SidebarVisibility.compute(sessions: [loose, direct, nested], groups: groups,
            importedHostsCount: 0, search: try! FileSearch.compile(query: "Nested", isRegex: false).get())
        #expect(SidebarVisibleRows.build(under: nil, visibility: searching, collapsed: collapsed,
                                        hiddenEntries: hidden).contains { $0.id == nested.id })

        let tunnelRoot = TunnelGroup(name: "Root")
        let tunnelChild = TunnelGroup(name: "Child", parentID: tunnelRoot.id)
        let tunnelGrandchild = TunnelGroup(name: "Grandchild", parentID: tunnelChild.id)
        let tunnelGroups = [tunnelRoot, tunnelChild, tunnelGrandchild]
        let profiles = [nil, tunnelRoot.id, tunnelGrandchild.id].enumerated().map { index, group in
            TunnelProfile(sessionID: UUID(), name: "Profile \(index)",
                kind: .dynamic(bind: "127.0.0.1", localPort: 19080 + index), groupID: group)
        }
        let hiddenTunnels = Set(tunnelGroups.map(\.id))
        let collapsedTunnels = hiddenTunnels.subtracting(Set(tunnelGroups.compactMap(\.parentID)))
        #expect(TunnelCatalog.sidebarRows(groups: tunnelGroups, profiles: profiles, collapsed: collapsedTunnels,
            hiddenEntries: hiddenTunnels).map(\.id) == [profiles[0].id, tunnelRoot.id, tunnelChild.id, tunnelGrandchild.id])
        #expect(TunnelCatalog.sidebarRows(groups: tunnelGroups, profiles: profiles, collapsed: [],
            hiddenEntries: hiddenTunnels.subtracting([tunnelGrandchild.id])).map(\.id)
            == [profiles[0].id, tunnelRoot.id, tunnelChild.id, tunnelGrandchild.id, profiles[2].id])
    }

    @Test func repeatedCollapseKeepsSiblingAndNestedRowIdentitiesStable() {
        let first = StoredGroup(name: "First", position: 0)
        let nested = StoredGroup(name: "Nested", parentID: first.id)
        let second = StoredGroup(name: "Second", position: 1)
        let child = StoredSession(name: "child", groupID: nested.id)
        let sibling = StoredSession(name: "sibling", groupID: second.id)
        let tree = visibility([first, nested, second], [child, sibling])
        var collapsed: Set<UUID> = []
        let original = SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed)
        #expect(original.map(\.id) == [first.id, nested.id, child.id, second.id, sibling.id])
        #expect(original.map(\.depth) == [0, 1, 2, 0, 1])
        #expect(original.map(\.startsSection) == [false, false, false, true, false])
        for _ in 0..<5 {
            collapsed = SidebarFolderDisclosure.collapsed(collapsed, setting: first.id, open: false, expandsFolders: false)!
            let closed = SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed)
            #expect(closed.map(\.id) == [first.id, second.id, sibling.id])
            #expect(closed.suffix(2) == original.suffix(2))
            collapsed = SidebarFolderDisclosure.collapsed(collapsed, setting: first.id, open: true, expandsFolders: false)!
            #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed) == original)
        }
        collapsed = [nested.id]
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed).map(\.id)
                == [first.id, nested.id, second.id, sibling.id])
        collapsed.insert(first.id)
        collapsed.remove(first.id)
        #expect(SidebarVisibleRows.build(under: nil, visibility: tree, collapsed: collapsed).map(\.id)
                == [first.id, nested.id, second.id, sibling.id])
    }

    @Test func chevronHasAFullHitAreaAndDoesNotSelectTheGroup() throws {
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let header = try SourceCorpus.code(of: root.appendingPathComponent("SidebarGroupHeader.swift"))
        #expect(header.contains("Button { isExpanded.toggle() }"))
        #expect(header.contains(".frame(width: 18, height: 24)"))
        #expect(header.contains(".contentShape(Rectangle())"))
        #expect(header.contains("label()"))
        #expect(!header.contains("onSelectGroup"))
        let sidebar = try SourceCorpus.code(of: root.appendingPathComponent("SessionSidebar.swift"))
        #expect(sidebar.contains("let rows = SidebarVisibleRows.build("))
        #expect(sidebar.contains("ForEach(rows)"))
        #expect(!sidebar.contains("AnyView("))
        #expect(sidebar.contains("SidebarGroupBands.connections(rows"))
        #expect(sidebar.contains(".listRowBackground(SidebarGroupBandBackground("))
        #expect(!sidebar.contains("alternateBand"))
    }
}
