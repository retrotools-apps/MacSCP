import Testing
@testable import macSCPCore

@Suite("Display name ordering")
struct DisplayNameOrderTests {
    @Test func connectionsPrecedeAlphabeticalGroupsAtEveryHierarchyLevel() {
        let root = StoredGroup(name: "A root")
        let child = StoredGroup(name: "A child", parentID: root.id)
        let sibling = StoredGroup(name: "B child", parentID: root.id)
        let nested = StoredGroup(name: "A nested", parentID: child.id)
        let loose = sshSession(name: "Zulu loose")
        let z = sshSession(name: "Zulu", groupID: root.id)
        let a = sshSession(name: "Alpha", groupID: root.id)
        let deep = sshSession(name: "Zulu deep", groupID: child.id)
        let tree = SidebarOrdering.Tree(groups: [sibling, nested, child, root], sessions: [z, loose, deep, a])
        #expect(SidebarOrdering.alphabeticalChildren(of: nil, in: tree) == [.session(loose.id), .group(root.id)])
        #expect(SidebarOrdering.alphabeticalChildren(of: root.id, in: tree)
            == [.session(a.id), .session(z.id), .group(child.id), .group(sibling.id)])
        #expect(SidebarOrdering.alphabeticalChildren(of: child.id, in: tree)
            == [.session(deep.id), .group(nested.id)])
    }

    @Test func everyGroupAndSubgroupIgnoresCreationAndPlacementOrder() {
        let root = StoredGroup(name: "Root")
        let sub10 = StoredGroup(name: "Group 10", parentID: root.id, position: 0)
        let sub2 = StoredGroup(name: "Group 2", parentID: root.id, position: 9)
        var z = sshSession(name: "Zulu", groupID: sub2.id)
        z.position = 0
        var a = sshSession(name: "Alpha", groupID: sub2.id)
        a.position = 99
        let elsewhere = sshSession(name: "Elsewhere", groupID: sub10.id)
        let visibility = SidebarVisibility.compute(sessions: [z, elsewhere, a],
            groups: [root, sub10, sub2], importedHostsCount: 0, search: nil)
        #expect(visibility.children(of: root.id) == [.group(sub2.id), .group(sub10.id)])
        #expect(visibility.children(of: sub2.id) == [.session(a.id), .session(z.id)])
        #expect(visibility.children(of: sub10.id) == [.session(elsewhere.id)])
        #expect(visibility.session(z.id)?.groupID == sub2.id)
        #expect(visibility.session(a.id)?.position == 99)
    }

    @Test func namesAreCaseInsensitiveAndNumbersAreNatural() {
        let names = ["zebra", "host 10", "beta", "Alpha", "host 2"]
        #expect(DisplayNameOrder.sorted(names, by: { $0 })
            == ["Alpha", "beta", "host 2", "host 10", "zebra"])
    }

    @Test func equalNamesKeepTheirRelativeOrder() {
        let values = [(name: "same", id: 2), (name: "same", id: 1)]
        #expect(DisplayNameOrder.sorted(values, by: \.name).map(\.id) == [2, 1])
    }
}
