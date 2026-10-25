import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit

@Suite("Sidebar group action artwork")
@MainActor
struct SidebarGroupActionIconTests {
    @Test(arguments: SidebarGroupActionIcon.Action.allCases, ["black", "white", "color", "color-dark"])
    func everyVariantIsPackagedAsVectorArtwork(action: SidebarGroupActionIcon.Action, style: String) throws {
        let image = try #require(SidebarGroupActionIcon.image(action: action, style: style))
        #expect(image.isValid)
        #expect(image.representations.contains { $0 is NSPDFImageRep })
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func bothActionsRenderAtToolbarSize(scheme: ColorScheme) throws {
        let view = HStack(spacing: 8) {
            SidebarGroupActionIcon(action: .collapse)
            SidebarGroupActionIcon(action: .expand)
        }
        .padding(12)
        .background(scheme == .dark ? Color(red: 0.15, green: 0.15, blue: 0.15) : .white)
        .environment(\.colorScheme, scheme)
        let image = try #require(ImageRenderer(content: view).nsImage)
        #expect(image.isValid)
    }
}
