import Foundation
import Testing
@testable import macSCPCore

@Suite("Custom group colors and palette")
struct GroupColorTests {
    @Test func anExactRGBColorIncludingGraySurvivesEncoding() throws {
        for hex in ["#808080", "#123456", "#000000", "#FFFFFF", "#BED8B6"] {
            let value = try #require(GroupColor(hex: hex))
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(GroupColor.self, from: data) == value)
            #expect(value.hex == hex)
            let group = StoredGroup(name: "Services", color: value)
            #expect(try JSONDecoder().decode(StoredGroup.self, from: JSONEncoder().encode(group)) == group)
            let tunnel = TunnelGroup(name: "Tunnels", color: value)
            #expect(try JSONDecoder().decode(TunnelGroup.self, from: JSONEncoder().encode(tunnel)) == tunnel)
        }
        for invalid in ["#123", "#00000000", "zzzzzz", " FF0000", "#１２３４５６"] {
            #expect(GroupColor(hex: invalid) == nil)
        }
    }

    @Test func aCustomChoiceOnlyReplacesANearbyUnusedSwatch() {
        let near = GroupColor(rgb: 0x808080), custom = GroupColor(rgb: 0x818181)
        let distant = GroupColor(rgb: 0xFF0000)
        let palette = [near, distant]
        #expect(GroupColorPalette.adding(custom, to: palette, used: []) == [custom, distant])
        #expect(GroupColorPalette.adding(custom, to: palette, used: [near]) == [near, distant, custom])
        #expect(GroupColorPalette.adding(distant, to: palette, used: []) == palette)
        let blue = GroupColor(rgb: 0x0000FF)
        #expect(GroupColorPalette.adding(blue, to: palette, used: []) == palette + [blue])
        #expect(near.distance(to: near) == 0)
        #expect(near.distance(to: custom) == custom.distance(to: near))
    }

    @MainActor @Test func savingRenamingAndResettingGroupsPreservesExactColor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let color = GroupColor(rgb: 0x7890AB)
        let store = SessionStore(directory: root)
        let group = StoredGroup(name: "Services", color: color)
        try store.upsertGroup(group)
        let restored = try #require(try store.allGroups().first)
        #expect(restored.color == color)
        let tunnels = TunnelStore(directory: root)
        var tunnel = TunnelGroup(name: "Tunnels", color: color)
        try tunnels.upsertGroup(tunnel)
        tunnel.name = "Renamed"
        try tunnels.upsertGroup(tunnel)
        #expect(tunnels.allGroups().first?.color == color)
        tunnel.color = nil
        try tunnels.upsertGroup(tunnel)
        #expect(tunnels.allGroups().first?.color == nil)
    }
}
