import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit
import macSCPCore

@Suite("Hierarchical sidebar group regions")
@MainActor struct SidebarGroupBandsTests {
    @Test func theLastEntryReservesSeparateSpaceForItsGroupAndEveryClosingAncestor() throws {
        let root = StoredGroup(name: "Root")
        let child = StoredGroup(name: "Child", parentID: root.id)
        let first = UUID(), last = UUID()
        let layers = SidebarGroupBands.build(entries: [
            .init(id: root.id, groupID: root.id),
            .init(id: child.id, groupID: child.id),
            .init(id: first, groupID: child.id),
            .init(id: last, groupID: child.id)
        ], groups: [root, child].map(SidebarGroupBands.Group.init))
        #expect(SidebarGroupBands.bottomContentInset(for: []) == 0)
        #expect(SidebarGroupBands.bottomContentInset(for: try #require(layers[first])) == 0)
        let ending = try #require(layers[last])
        #expect(ending.count == 2 && ending.allSatisfy(\.ends))
        #expect(SidebarGroupBands.bottomContentInset(for: ending) == 16)
        #expect(SidebarGroupBands.bottomBackgroundInset(for: ending[0], in: ending) == 0)
        #expect(SidebarGroupBands.bottomBackgroundInset(for: ending[1], in: ending) == 8)
    }

    @Test func collapsedHeadersReserveOnlyTheirEnclosingFrame() throws {
        let root = StoredGroup(name: "Root")
        let child = StoredGroup(name: "Child", parentID: root.id)
        let rootOnly = SidebarGroupBands.build(entries: [.init(id: root.id, groupID: root.id)], groups: [.init(root)])
        #expect(SidebarGroupBands.headerBottomInset(for: try #require(rootOnly[root.id])) == 0)
        let nested = SidebarGroupBands.build(entries: [.init(id: root.id, groupID: root.id), .init(id: child.id, groupID: child.id)], groups: [root, child].map(SidebarGroupBands.Group.init))
        #expect(SidebarGroupBands.headerBottomInset(for: try #require(nested[root.id])) == 0)
        let closing = try #require(nested[child.id])
        #expect(SidebarGroupBands.headerBottomInset(for: closing) == 8)
        #expect(SidebarGroupBands.headerBottomInset(for: closing)
            == SidebarGroupBands.bottomBackgroundInset(for: try #require(closing.last), in: closing))
    }

    @Test func exactColorFlowsIntoEveryGroupBandWithoutChangingSiblingColors() throws {
        let rgb = GroupColor(rgb: 0x123456)
        let root = StoredGroup(name: "Root", color: rgb)
        let child = StoredGroup(name: "Child", parentID: root.id, color: GroupColor(rgb: 0x808080))
        let layers = SidebarGroupBands.build(entries: [.init(id: child.id, groupID: child.id)],
            groups: [root, child].map(SidebarGroupBands.Group.init))
        #expect(layers[child.id]?.map(\.color) == [rgb, child.color])
        let roundtrip = try #require(GroupColor(color: rgb.swiftUIColor))
        #expect(roundtrip == rgb)
    }

    @Test func neutralGroupRegionsAlternateAcrossSiblingsAndNestingWithoutChangingSavedHues() throws {
        let root = StoredGroup(name: "A", colorHue: 0.76)
        let second = StoredGroup(name: "B", colorHue: 0.76)
        let child = StoredGroup(name: "A child", parentID: root.id, colorHue: 0.76)
        let sibling = StoredGroup(name: "B child", parentID: root.id, colorHue: 0.76)
        let groups = [root, second, child, sibling].map(SidebarGroupBands.Group.init)
        let variants = SidebarGroupBands.neutralVariants(groups: groups)
        #expect(variants[root.id] == false)
        #expect(variants[second.id] == true)
        #expect(variants[child.id] == true)
        #expect(variants[sibling.id] == false)
        #expect(SidebarGroupBands.neutralVariants(groups: groups.reversed()) == variants)
        #expect(SidebarGroupBands.hues(groups: groups).values.allSatisfy { $0 == 0.76 })
        let bands = SidebarGroupBands.build(entries: [.init(id: child.id, groupID: child.id)], groups: groups)
        #expect(bands[child.id]?.map(\.darkerNeutral) == [false, true])
        for dark in [false, true] {
            let lighter = GroupNeutralStyle.opacity(darker: false, dark: dark)
            let darker = GroupNeutralStyle.opacity(darker: true, dark: dark)
            #expect(lighter > 0 && lighter < darker && darker <= 0.1)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func compactPickerOffersQuickSwatchesAndCustomColorWithoutCredentialAccess(scheme: ColorScheme) async throws {
        #expect(!GroupColorPicker.swatches.isEmpty)
        #expect(Set(GroupColorPicker.swatches).count == GroupColorPicker.swatches.count)
        let view = GroupColorPicker(hue: 0.76, onChange: { _ in })
            .background(DesignTokens.sidebarSurface).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.isValid)
    }

    @Test func customGroupColorsOverrideAutomaticHuesAndResetWithoutAffectingSiblings() throws {
        var root = StoredGroup(name: "Root", colorHue: 0.08)
        var child = StoredGroup(name: "Child", parentID: root.id, colorHue: 0.76)
        let sibling = StoredGroup(name: "Sibling", parentID: root.id)
        func palette() -> [UUID: Double] {
            SidebarGroupBands.hues(groups: [root, child, sibling].map(SidebarGroupBands.Group.init))
        }
        let custom = palette()
        #expect(custom[root.id] == 0.08)
        #expect(custom[child.id] == 0.76)
        child.colorHue = nil
        #expect(palette()[child.id] != 0.76)
        #expect(palette()[sibling.id] == custom[sibling.id])
        root.colorHue = .nan
        #expect(try #require(palette()[root.id]).isFinite)
        let tunnel = TunnelGroup(name: "Tunnel", colorHue: 0.32)
        #expect(SidebarGroupBands.hues(groups: [.init(tunnel)])[tunnel.id] == 0.32)
    }

    @Test func siblingHuesAreSeparatedAndSharedByContentDespiteFiltering() throws {
        let root = StoredGroup(name: "Phantom")
        let children = ["Deception", "Services", "Tools"].map { StoredGroup(name: $0, parentID: root.id) }
        let groups = ([root] + children).map(SidebarGroupBands.Group.init)
        let hues = SidebarGroupBands.hues(groups: groups)
        let reversed = SidebarGroupBands.hues(groups: groups.reversed())
        #expect(hues == reversed)
        for (index, child) in children.enumerated() {
            let hue = try #require(hues[child.id])
            let parentHue = try #require(hues[root.id])
            let distance = abs(hue - parentHue)
            #expect(min(distance, 1 - distance) > 0.1)
            for sibling in children.dropFirst(index + 1) {
                let delta = abs(hue - (try #require(hues[sibling.id])))
                #expect(min(delta, 1 - delta) > 0.1)
            }
            let item = UUID()
            let bands = SidebarGroupBands.build(entries: [.init(id: item, groupID: child.id)], groups: groups)
            #expect(bands[item]?.last?.hue == hue)
        }
        #expect(SidebarGroupBands.hues(groups: []).isEmpty)
    }

    @Test func contentTintsRemainSubtleAndTunnelRowsStayNeutral() {
        for dark in [false, true] {
            #expect(GroupTintStyle.cardOpacity(dark: dark) <= 0.06)
            for alternate in [false, true] {
                #expect(GroupTintStyle.tunnelRowOpacity(alternate: alternate, dark: dark) <= 0.04)
            }
            #expect(GroupTintStyle.tunnelAccentOpacity(dark: dark)
                    > GroupTintStyle.cardOpacity(dark: dark))
        }
        #expect(GroupTintStyle.cardNeutralOpacity(darker: false, dark: false) == 0)
        #expect(GroupTintStyle.cardNeutralOpacity(darker: true, dark: false) == 0)
        #expect(GroupTintStyle.tunnelRowOpacity(alternate: false, dark: false) == 0)
        #expect(GroupTintStyle.tunnelRowOpacity(alternate: true, dark: false) == 0)
        #expect(GroupTintStyle.cardNeutralOpacity(darker: true, dark: true) > 0)
        #expect(GroupTintStyle.tunnelRowOpacity(alternate: true, dark: true) > 0)
    }

    @Test func regionsIncludeHeadersContentsAndNestedGroupsWithoutIncludingLooseConnections() throws {
        let root = StoredGroup(name: "Home")
        let child = StoredGroup(name: "Tools", parentID: root.id)
        let other = StoredGroup(name: "Services")
        let loose = UUID(), direct = UUID(), nested = UUID(), last = UUID()
        let entries: [SidebarGroupBands.Entry] = [
            .init(id: loose, groupID: nil), .init(id: root.id, groupID: root.id),
            .init(id: direct, groupID: root.id), .init(id: child.id, groupID: child.id),
            .init(id: nested, groupID: child.id), .init(id: other.id, groupID: other.id),
            .init(id: last, groupID: other.id)]
        let groups = [root, child, other].map(SidebarGroupBands.Group.init)
        let plan = SidebarGroupBands.build(entries: entries, groups: groups)
        #expect(plan[loose]?.isEmpty == true)
        let rootHeader = try #require(plan[root.id]?.first)
        #expect(rootHeader.starts && !rootHeader.ends)
        #expect(plan[direct]?.map(\.groupID) == [root.id])
        #expect(plan[child.id]?.map(\.groupID) == [root.id, child.id])
        #expect(plan[nested]?.map(\.groupID) == [root.id, child.id])
        #expect(plan[nested]?.allSatisfy(\.ends) == true)
        #expect(plan[child.id]?.last?.starts == true)
        #expect(plan[nested]?.first?.hue == rootHeader.hue)
        #expect(plan[child.id]?.last?.hue != rootHeader.hue)
        #expect(plan[other.id]?.first?.hue != rootHeader.hue)
        #expect(plan[root.id]?.first?.endFraction == plan[direct]?.first?.startFraction)
        let filtered = SidebarGroupBands.build(entries: Array(entries.suffix(2)), groups: groups)
        #expect(filtered[other.id]?.first?.hue == plan[other.id]?.first?.hue)
        let collapsed = SidebarGroupBands.build(entries: [.init(id: root.id, groupID: root.id)], groups: groups)
        #expect(collapsed[root.id]?.first?.starts == true)
        #expect(collapsed[root.id]?.first?.ends == true)
    }
}
