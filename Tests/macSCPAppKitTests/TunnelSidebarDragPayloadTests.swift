import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Tunnel sidebar drag payload")
struct TunnelSidebarDragPayloadTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func groupRoundTrips() throws {
        let id = UUID()
        #expect(TunnelSidebarDragPayload(text: TunnelSidebarDragPayload.group(id).text) == .group(id))
    }

    @Test func profileRoundTrips() throws {
        let id = UUID()
        #expect(TunnelSidebarDragPayload(text: TunnelSidebarDragPayload.profile(id).text) == .profile(id))
    }

    @Test func foreignPayloadIsRejected() {
        #expect(TunnelSidebarDragPayload(text: "macscp.sidebar.session:\(UUID())") == nil)
    }

    @Test func tunnelRowsUseNativeSourcesWithoutEnrollingListCells() throws {
        let source = try SourceCorpus.code(of: Self.repoRoot.appendingPathComponent(
            "Sources/MacSCPAppKit/TunnelWorkspaceSidebar.swift"))
        let nativeSourceCount = source.components(separatedBy: "SidebarDragSourceView(").count - 1
        let hasSwiftUIListSource = source.contains(".onDrag") || source.contains(".draggable(")

        #expect(nativeSourceCount == 2, "both tunnel groups and profiles need native drag sources")
        #expect(hasSwiftUIListSource == false, "a tunnel List row is still a SwiftUI drag source")
    }
}
