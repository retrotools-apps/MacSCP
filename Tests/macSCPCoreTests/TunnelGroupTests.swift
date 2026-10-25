import Foundation
import Testing
@testable import macSCPCore

@Suite("Tunnel groups")
struct TunnelGroupTests {
    @Test func groupColorPersistsAcrossRenameMoveAndLegacyDecoding() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = TunnelGroup(name: "Root")
        var group = TunnelGroup(name: "Services", colorHue: 0.76)
        try store.upsertGroup(parent)
        try store.upsertGroup(group)
        group.name = "Renamed"
        group.parentID = parent.id
        try store.upsertGroup(group)
        #expect(store.allGroups().first { $0.id == group.id }?.colorHue == 0.76)
        group.colorHue = nil
        try store.upsertGroup(group)
        #expect(store.allGroups().first { $0.id == group.id }?.colorHue == nil)
        let legacy = Data("{\"id\":\"\(UUID())\",\"name\":\"Legacy\"}".utf8)
        #expect(try JSONDecoder().decode(TunnelGroup.self, from: legacy).colorHue == nil)
    }

    @Test func nestedGroupsRoundtripAndRejectCyclesWithoutWriting() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = TunnelGroup(name: "Production")
        let child = TunnelGroup(name: "Web", parentID: root.id)
        let grandchild = TunnelGroup(name: "API", parentID: child.id)
        for group in [root, child, grandchild] { try store.upsertGroup(group) }
        #expect(store.allGroups().first { $0.id == grandchild.id } == grandchild)
        #expect(TunnelGroup.subtree(root.id, in: store.allGroups()) == [root.id, child.id, grandchild.id])
        #expect(TunnelGroup.path(grandchild, in: store.allGroups()) == "Production / Web / API")
        let before = try Data(contentsOf: directory.appendingPathComponent("tunnels.json"))
        var cyclic = root
        cyclic.parentID = grandchild.id
        #expect(throws: TunnelGroupError.invalidParent) { try store.upsertGroup(cyclic) }
        cyclic.parentID = root.id
        #expect(throws: TunnelGroupError.invalidParent) { try store.upsertGroup(cyclic) }
        cyclic.parentID = UUID()
        #expect(throws: TunnelGroupError.missingGroup) { try store.upsertGroup(cyclic) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("tunnels.json")) == before)
    }

    @Test func duplicateNamesAreScopedToSiblingsAndDissolutionPromotesChildren() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = TunnelGroup(name: "Production"), other = TunnelGroup(name: "Development")
        let child = TunnelGroup(name: "Web", parentID: root.id)
        let peer = TunnelGroup(name: "Web", parentID: other.id)
        for group in [root, other, child, peer] { try store.upsertGroup(group) }
        let tunnel = mapping(groupID: child.id)
        try store.upsert(tunnel)
        #expect(throws: TunnelGroupError.duplicateName) {
            try store.upsertGroup(TunnelGroup(name: "web", parentID: root.id))
        }
        try store.deleteGroup(id: root.id)
        #expect(store.allGroups().first { $0.id == child.id }?.parentID == nil)
        #expect(store.allProfiles() == [tunnel])
        #expect(store.allGroups().first { $0.id == peer.id } == peer)
    }

    @Test func conflictingPromotionRefusesToLoseOrRenameGroups() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = TunnelGroup(name: "Production"), top = TunnelGroup(name: "Web")
        for group in [root, top, TunnelGroup(name: "Web", parentID: root.id)] { try store.upsertGroup(group) }
        let before = try Data(contentsOf: directory.appendingPathComponent("tunnels.json"))
        #expect(throws: TunnelGroupError.duplicateName) { try store.deleteGroup(id: root.id) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("tunnels.json")) == before)
    }

    @Test func oldGroupDocumentsDefaultToRootAndTraversalBoundsCycles() throws {
        let group = TunnelGroup(name: "Legacy")
        let data = try JSONSerialization.data(withJSONObject: ["id": group.id.uuidString, "name": group.name])
        #expect(try JSONDecoder().decode(TunnelGroup.self, from: data) == group)
        var a = TunnelGroup(name: "A"), b = TunnelGroup(name: "B")
        a.parentID = b.id; b.parentID = a.id
        #expect(TunnelGroup.subtree(a.id, in: [a, b]) == [a.id, b.id])
        #expect(TunnelGroup.subtree(UUID(), in: [a, b]).isEmpty)
    }

    private func fixture() -> (TunnelStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (TunnelStore(directory: directory), directory)
    }

    private func mapping(groupID: UUID? = nil) -> TunnelProfile {
        TunnelProfile(sessionID: UUID(), name: "Web", kind: .dynamic(bind: "127.0.0.1", localPort: 19080), groupID: groupID)
    }

    @Test func groupsRoundtripAlongsideProfilesAndRenameKeepsMembership() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var group = TunnelGroup(name: "Production")
        try store.upsertGroup(group)
        let profile = mapping(groupID: group.id)
        try store.upsert(profile)
        let reopened = TunnelStore(directory: directory)
        #expect(reopened.allGroups() == [group])
        #expect(reopened.allProfiles() == [profile])
        group.name = "Infrastructure"
        try reopened.upsertGroup(group)
        #expect(store.allGroups() == [group])
        #expect(store.allProfiles() == [profile])
    }

    @Test func legacyDocumentsWithoutGroupsRemainReadableAndKeepProfiles() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = mapping()
        try store.upsert(original)
        let file = directory.appendingPathComponent("tunnels.json")
        let legacy = try Data(contentsOf: file)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("groups"))
        #expect(store.allGroups().isEmpty)
        #expect(store.allProfiles() == [original])
        try store.upsertGroup(TunnelGroup(name: "Development"))
        #expect(store.allProfiles() == [original])
    }

    @Test func dissolvingAGroupPreservesProfilesAndOtherGroups() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = TunnelGroup(name: "Old"), survivor = TunnelGroup(name: "Production")
        try store.upsertGroup(removed)
        try store.upsertGroup(survivor)
        var moved = mapping(groupID: removed.id)
        let untouched = mapping(groupID: survivor.id)
        try store.upsert(moved)
        try store.upsert(untouched)
        try store.deleteGroup(id: removed.id)
        moved.groupID = nil
        #expect(store.allProfiles() == [moved, untouched])
        #expect(store.allGroups() == [survivor])
    }

    @Test func invalidGroupWritesLeaveTheFileUnchanged() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = TunnelGroup(name: "Production")
        try store.upsertGroup(group)
        let file = directory.appendingPathComponent("tunnels.json")
        let before = try Data(contentsOf: file)
        #expect(throws: TunnelGroupError.emptyName) { try store.upsertGroup(TunnelGroup(name: "  \n")) }
        #expect(throws: TunnelGroupError.duplicateName) { try store.upsertGroup(TunnelGroup(name: "production")) }
        #expect(throws: TunnelGroupError.missingGroup) { try store.upsert(mapping(groupID: UUID())) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func groupOperationsNeverReplaceAnUnreadableStore() throws {
        let (store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tunnels.json")
        let corrupt = Data("unreadable fixture".utf8)
        try corrupt.write(to: file)
        #expect(throws: TunnelStoreError.self) { try store.upsertGroup(TunnelGroup(name: "Production")) }
        #expect(throws: TunnelStoreError.self) { try store.deleteGroup(id: UUID()) }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
