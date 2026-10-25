import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit
import macSCPCore

@Suite("Compact sidebar session identity")
@MainActor
struct SessionSidebarIdentityTests {
    @Test func onlyConfiguredAndAvailableIconsReplaceTheStatusDot() {
        let cases: [(SessionAppearance, Bool)] = [
            (.init(), false), (.init(tint: .orange), false),
            (.init(icon: .bastion), true), (.init(applicationLogo: "mysql"), true),
            (.init(applicationLogo: "unknown-future-logo"), false),
            (.init(icon: .server, applicationLogo: "unknown-future-logo"), true)
        ]
        for (appearance, expected) in cases {
            let view = SessionSidebarIdentity(appearance: appearance, kind: .ssh, isConnected: false)
            #expect(view.showsConfiguredIcon == expected)
        }
    }

    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func configuredIconsAndFallbackDotsKeepTheSameSmallFootprint(connected: Bool, scheme: ColorScheme) throws {
        for appearance: SessionAppearance in [.init(), .init(icon: .bastion, tint: .orange),
                                               .init(applicationLogo: "mysql"),
                                               .init(applicationLogo: "aws-service-amazon-ec2")] {
            let renderer = ImageRenderer(content: SessionSidebarIdentity(appearance: appearance, kind: .ssh,
                isConnected: connected).environment(\.colorScheme, scheme))
            let image = try #require(renderer.nsImage)
            #expect(image.size == NSSize(width: 14, height: 14))
            #expect(image.isValid)
        }
    }
}
