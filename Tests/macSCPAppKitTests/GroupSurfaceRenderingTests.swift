import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit
import macSCPCore

@MainActor struct GroupSurfaceRenderingTests {
    private func pixel<V: View>(_ view: V, at point: CGPoint) throws -> GroupColor {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let color = try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
        #expect(color.alphaComponent == 1)
        return try #require(GroupColor(color: Color(nsColor: color)))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func highContrastSubgroupsAndCardsRenderTheSameColorWhateverTheParent(scheme: ColorScheme) throws {
        let childColor = GroupColor(rgb: 0xE673AC)
        let child = StoredGroup(name: "Child", color: childColor)
        let card = try pixel(GroupContentTint(hue: 0.2, customColor: childColor)
            .frame(width: 40, height: 40).environment(\.highContrast, true).environment(\.colorScheme, scheme), at: CGPoint(x: 20, y: 20))
        for parentColor in [GroupColor(rgb: 0xE6E673), GroupColor(rgb: 0x007AFF)] {
            let parent = StoredGroup(name: "Parent", color: parentColor)
            var nested = child
            nested.parentID = parent.id
            let first = UUID(), last = UUID()
            let bands = SidebarGroupBands.build(entries: [.init(id: parent.id, groupID: parent.id), .init(id: child.id, groupID: child.id), .init(id: first, groupID: child.id), .init(id: last, groupID: child.id)], groups: [parent, nested].map(SidebarGroupBands.Group.init))
            let sidebar = try pixel(SidebarGroupBandBackground(layers: try #require(bands[first]))
                .frame(width: 40, height: 40).environment(\.highContrast, true).environment(\.colorScheme, scheme), at: CGPoint(x: 20, y: 20))
            #expect(sidebar == card)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func selectingACollapsedGroupDoesNotChangeItsInteriorSurface(scheme: ColorScheme) throws {
        let color = GroupColor(rgb: 0xE6E673)
        let surface = GroupSurfaceStyle.surface(hue: 0.2, customColor: color, darkerNeutral: false, dark: scheme == .dark, colorsEnabled: true)
        func header(selected: Bool) -> some View {
            SidebarGroupHeader(isExpanded: .constant(false), name: "Parent", isSelected: selected) {
                SidebarGroupTitle(name: "Parent")
                Spacer()
            }
            .frame(width: 240, height: 36).background(surface)
            .environment(\.highContrast, true).environment(\.colorScheme, scheme)
        }
        let selected = try pixel(header(selected: true), at: CGPoint(x: 150, y: 18))
        let unselected = try pixel(header(selected: false), at: CGPoint(x: 150, y: 18))
        #expect(selected == unselected)
    }

    @Test func highContrastPreservesTheSolidChosenColorAndUsesReadableInk() throws {
        for color in GroupColorPalette.defaults + [GroupColor(rgb: 0x123456), GroupColor(rgb: 0xFFFFFF)] {
            let surface = GroupSurfaceStyle.color(hue: 0.2, customColor: color, darkerNeutral: false, dark: false, colorsEnabled: true)
            #expect(surface == color)
            let foreground = try #require(GroupColor(color: GroupSurfaceStyle.foreground(hue: 0.2,
                customColor: color, darkerNeutral: false, dark: false, colorsEnabled: true)))
            let contrast = (max(surface.relativeLuminance, foreground.relativeLuminance) + 0.05)
                / (min(surface.relativeLuminance, foreground.relativeLuminance) + 0.05)
            #expect(contrast >= 4.5)
        }
    }

}
