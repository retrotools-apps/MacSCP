import Foundation
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The sidebar's drag payload — the App-layer counterpart of `TabDropPlan`,
/// and for the same reason: a drop destination learns nothing about what is
/// being carried until the drop happens, so the payload is the one place the
/// dragged row can name itself.
///
/// What it names is a `SidebarItem`, not a bare uuid, because the sidebar's
/// two gestures act on two KINDS of row: dropping on a folder puts the
/// dragged row inside it, dropping on a connection puts it in that
/// connection's place. A bare uuid would leave the kind to be guessed from a
/// lookup, and a lookup that misses (a row deleted mid-drag) is
/// indistinguishable from a lookup for the other kind.
@Suite("Sidebar drag payload")
struct SidebarDragPayloadTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func aFolderRoundTripsAsAFolder() {
        let id = UUID()
        let payload = SidebarDragPayload.text(for: .group(id))
        #expect(SidebarDragPayload.item(from: [payload]) == .group(id))
    }

    @Test func aConnectionRoundTripsAsAConnection() {
        let id = UUID()
        let payload = SidebarDragPayload.text(for: .session(id))
        #expect(SidebarDragPayload.item(from: [payload]) == .session(id))
    }

    /// A row-level SwiftUI drag source makes `List` retain its source cell
    /// while the model moves the connection. After an out-and-back move that
    /// retained cell is the blank row reported between a folder header and
    /// its first connection. Keep the AppKit source present and the List row
    /// free of both SwiftUI drag-source spellings.
    @Test func aConnectionDragDoesNotEnrollItsListRowAsTheSource() throws {
        let app = Self.repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let sidebar = try SourceCorpus.code(of: app.appendingPathComponent("SessionSidebar.swift"))
        let source = try SourceCorpus.code(of: app.appendingPathComponent("SidebarDrag.swift"))
        let sessionRowStart = try #require(sidebar.range(of: "private struct SessionRow"))
        let sessionRow = sidebar[sessionRowStart.lowerBound...]

        let hasAppKitSource = sessionRow.contains("SidebarDragSourceView(")
            && source.contains("NSDraggingSource")
            && source.contains("beginDraggingSession(")
        let hasSwiftUIListSource = sessionRow.contains(".onDrag")
            || sessionRow.contains(".draggable(")

        #expect(hasAppKitSource, "connection rows have no native drag source")
        #expect(hasSwiftUIListSource == false, "the List row is still a SwiftUI drag source")
    }

    @Test func aGroupDragDoesNotEnrollItsListRowAsTheSource() throws {
        let app = Self.repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let sidebar = try SourceCorpus.code(of: app.appendingPathComponent("SessionSidebar.swift"))
        let source = try SourceCorpus.code(of: app.appendingPathComponent("SidebarDrag.swift"))
        let groupRow = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private struct SidebarGroupRow: View", in: sidebar)

        let hasAppKitSource = groupRow.contains("SidebarDragSourceView(")
            && source.contains("NSDraggingSource")
            && source.contains("beginDraggingSession(")
        let hasSwiftUIListSource = groupRow.contains(".onDrag")
            || groupRow.contains(".draggable(")

        #expect(hasAppKitSource, "group rows have no native drag source")
        #expect(hasSwiftUIListSource == false, "the group List row is still a SwiftUI drag source")
    }

    /// The two spellings are distinct even for the same id, which is what
    /// makes the kind a fact the drop is told rather than one it infers.
    @Test func theTwoKindsAreSpelledDifferentlyForTheSameID() {
        let id = UUID()
        #expect(
            SidebarDragPayload.text(for: .group(id)) != SidebarDragPayload.text(for: .session(id)))
    }

    /// A tab dragged out of the tab strip carries a bare uuid string
    /// (`TabItemView.dragPayload`). It is not a sidebar row and must not be
    /// read as one — the mirror image of `TabDropPlan` refusing a sidebar
    /// payload, and the reason neither surface can move the other's rows.
    @Test func aBareUUIDFromTheTabStripIsNotASidebarRow() {
        #expect(SidebarDragPayload.item(from: [UUID().uuidString]) == nil)
    }

    @Test func nonsenseAndAnEmptyPayloadNameNothing() {
        #expect(SidebarDragPayload.item(from: []) == nil)
        #expect(SidebarDragPayload.item(from: ["group:not-a-uuid"]) == nil)
        #expect(SidebarDragPayload.item(from: ["/etc/passwd"]) == nil)
    }

    /// A drag carries one row, so anything past the first item belongs to a
    /// gesture this sidebar did not produce — the same rule `TabDropPlan`
    /// states for the strip.
    @Test func onlyTheFirstItemIsRead() {
        let first = UUID()
        let second = UUID()
        let payload = [
            SidebarDragPayload.text(for: .session(first)),
            SidebarDragPayload.text(for: .group(second)),
        ]
        #expect(SidebarDragPayload.item(from: payload) == .session(first))
    }
}
