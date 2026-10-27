import AppKit
import SwiftUI
import Testing
@testable import macSCPCore
@testable import MacSCPAppKit

@MainActor struct AppearanceRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func nativeAppearanceEditorsRender(scheme: ColorScheme) async throws {
        let appearance = SessionAppearance(icon: .server, customColor: GroupColor(rgb: 0x007AFF))
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let views: [(String, AnyView, NSSize)] = [
            ("picker", AnyView(SessionAppearancePicker(appearance: .constant(appearance), kind: .ssh).padding(24)), NSSize(width: 620, height: 170)),
            ("catalogue", AnyView(AppearanceCataloguePicker(appearance: .constant(appearance), kind: .ssh, onSelect: {})), NSSize(width: 460, height: 440)),
            ("editor", AnyView(TunnelWorkspaceEditor(profile: nil, sessions: [], manager: rig.manager, onClose: {})), NSSize(width: 900, height: 780))
        ]
        for (name, view, size) in views {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
            window.contentView = hosting
            window.orderBack(nil)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "\(name) did not render")
            window.close()
        }
    }
}
