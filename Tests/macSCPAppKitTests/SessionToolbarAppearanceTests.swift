import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit

@MainActor
@Suite("Session toolbar appearance")
struct SessionToolbarAppearanceTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func sshStaysCompactWithAReadableAccentInsteadOfASolidBlueBlock(scheme: ColorScheme) throws {
        let view = Button {} label: { Label("SSH", systemImage: "terminal") }
            .buttonStyle(SessionToolbarButtonStyle(prominent: true))
            .padding(8)
            .background(scheme == .light ? Color.white : Color.black)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        // Includes the preview's 8 pt margin on each side.
        #expect(image.width < 80)
        #expect(image.height == 38)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var bluePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.blueComponent > 0.45,
                   color.blueComponent > color.redComponent + 0.15,
                   color.blueComponent > color.greenComponent + 0.12 {
                    bluePixels += 1
                }
            }
        }
        #expect(bluePixels > 20, "The SSH glyph and label must retain their visible accent.")
        #expect(bluePixels < 600, "The SSH action must not become a large solid-color button.")
    }
}
