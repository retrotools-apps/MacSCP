import AppKit
import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Native connection status appearance")
struct ConnectionStatusAppearanceTests {
    @Test func tunnelMenuColorDistinguishesIdleHealthyAndTroubledTransports() {
        #expect(TunnelMenuSummary.tone(states: []) == .neutral)
        #expect(TunnelMenuSummary.tone(states: [.stopped]) == .neutral)
        #expect(TunnelMenuSummary.tone(states: [.active(connections: 0)]) == .healthy)
        #expect(TunnelMenuSummary.tone(states: [.active(connections: 1), .failed(.connectionFailed)]) == .warning)
        #expect(TunnelMenuSummary.tone(states: [.reconnecting(attempt: 1)]) == .warning)
        #expect(TunnelMenuSummary.tone(states: [.needsConfirmation]) == .warning)
        #expect(TunnelMenuSummary.tone(states: [.active(connections: 0, failedConnections: 3)]) == .warning)
    }

    @Test @MainActor func coloredMenuBarMarksPreserveTransparencyAndAreNotTemplates() throws {
        for color in [NSColor.systemGreen, .systemOrange] {
            let image = try #require(ApplicationIcon.tintedMenuBarImage(color))
            #expect(image.isValid)
            #expect(!image.isTemplate)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
        }
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test(arguments: ["exclamationmark.triangle", "network.slash", "network"])
    @MainActor func statusSymbolsExistOnTheSupportedSystem(name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    @Test @MainActor func menuBarUsesAValidTransparentApplicationMark() throws {
        let image = try #require(ApplicationIcon.menuBarImage())
        #expect(image.isValid)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let corner = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent == 0)
        let controller = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/MenuBarController.swift"))
        #expect(controller.contains("button.image = ApplicationIcon.menuBarImage()"))
    }

    @Test func statusSurfacesOccupyTheAvailableAreaAndCenterTheirContent() throws {
        let source = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift"))
        let names = ["LostConnectionView", "ConnectFailureView", "ConnectingAttemptView"]
        for name in names {
            let anchor = "private struct \(name): View"
            let start = try #require(source.range(of: anchor))
            let tail = source[start.upperBound...]
            let end = tail.range(of: "\nprivate struct ")?.lowerBound ?? tail.endIndex
            let body = tail[..<end]
            #expect(body.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"))
            #expect(body.contains(".buttonStyle(.bordered)"))
            #expect(!body.contains(".buttonStyle(.polished)"))
        }
    }
}
