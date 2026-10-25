import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
import macSCPCore

@Suite("Session sidebar editing lock")
struct SessionSidebarInteractionPlanTests {
    @Test @MainActor func realEditorLifecycleLocksAndUnlocksWithoutConnecting() {
        let form = ConnectionViewModel { _, _ in throw CancellationError() }
        let stored = StoredSession(name: "edited", kind: .ssh,
            ssh: StoredSSHConfig(host: "unit.invalid", username: "user", authKind: .agent))
        form.beginEditing(stored)
        #expect(SessionSidebarInteractionPlan.isDisabled(
            formModes: [form.mode], isConnecting: false, isReconnecting: false))
        // Both Save and Back use endEditing after their respective actions.
        form.endEditing()
        #expect(!SessionSidebarInteractionPlan.isDisabled(
            formModes: [form.mode], isConnecting: false, isReconnecting: false))
    }

    @Test func editingAlwaysLocksAndLeavingEditModeReleasesTheLock() {
        let editing = ConnectionViewModel.FormMode.edit(sessionID: UUID())
        for connecting in [false, true] {
            for reconnecting in [false, true] {
                #expect(SessionSidebarInteractionPlan.isDisabled(
                    formModes: [editing], isConnecting: connecting, isReconnecting: reconnecting))
                #expect(SessionSidebarInteractionPlan.isDisabled(
                    formModes: [.new], isConnecting: connecting, isReconnecting: reconnecting)
                    == (connecting || reconnecting))
            }
        }
    }

    @Test func selectingAnotherTabDoesNotBypassAnUnfinishedEditor() {
        #expect(SessionSidebarInteractionPlan.isDisabled(
            formModes: [.new, .edit(sessionID: UUID())], isConnecting: false, isReconnecting: false))
        #expect(!SessionSidebarInteractionPlan.isDisabled(
            formModes: [.new, .new], isConnecting: false, isReconnecting: false))
    }

    @Test func sidebarUsesTheLiveEditorModeAndBlocksPointerAndKeyboardSelection() throws {
        func code(_ name: String) throws -> String {
            try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/" + name))
        }
        let owner = try code("ContentView+Detail.swift")
        #expect(owner.contains("interactionsDisabled: sidebarInteractionsDisabled"))
        let lifecycle = try code("ContentView+Lifecycle.swift")
        #expect(lifecycle.contains("var sidebarInteractionsDisabled: Bool"))
        #expect(lifecycle.contains("SessionSidebarInteractionPlan.isDisabled("))
        #expect(lifecycle.contains("formModes: tabsModel.tabs.map { $0.connectionViewModel.mode }"))
        let sidebar = try code("SessionSidebar.swift")
        #expect(sidebar.contains(".disabled(interactionsDisabled)"))
        #expect(sidebar.contains(".allowsHitTesting(!interactionsDisabled)"))
        #expect(sidebar.contains("if interactionsDisabled {"))
        #expect(sidebar.contains(".fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))"))
        for anchor in ["private func activate(", "private func startNewConnection()", "private func moveSelection("] {
            let start = try #require(sidebar.range(of: anchor))
            let body = sidebar[start.upperBound...]
            let brace = try #require(body.firstIndex(of: "{"))
            #expect(body[body.index(after: brace)...].trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("guard !interactionsDisabled else"))
        }
    }
}
