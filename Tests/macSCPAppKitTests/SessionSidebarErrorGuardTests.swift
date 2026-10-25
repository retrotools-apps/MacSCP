import Foundation
import MacSCPTestSupport
import Testing

/// The saved-session sidebar retains group-move and Keychain-restore errors.
@Suite("Session sidebar error presentation")
struct SessionSidebarErrorGuardTests {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    @Test func bothCurrentBannersUseTheirOwnDismissalAndTheSharedBuilder() throws {
        let source = try SourceCorpus.code(of: Self.file)
        for (declaration, dismissal) in [
            ("private var groupMoveErrorBanner: some View", "viewModel.dismissError()"),
            ("private var jumpRestoreErrorBanner: some View", "self.jumpRestoreErrorMessage = nil"),
        ] {
            let body = try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: source)
            #expect(body.contains("sidebarErrorBanner(message:"))
            #expect(body.contains(dismissal))
        }
        let calls = TransferQueueBarCancelGuardTests.occurrenceCount(of: "sidebarErrorBanner(message:", in: source)
        #expect(calls == 2)
    }

    @Test func theSharedBannerClosesManuallyAndOnMessageScopedTimeout() throws {
        let source = try SourceCorpus.code(of: Self.file)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func sidebarErrorBanner(", in: source)
        #expect(body.contains("Button"))
        #expect(body.contains("onDismiss()"))
        #expect(body.contains(".task(id: message)"))
        #expect(body.contains("Task.sleep(for: Self.errorAutoDismissDelay)"))
        #expect(body.contains("catch"))
    }

    @Test func theCloseButtonHasHelpAndAnAccessibilityLabel() throws {
        let source = try SourceCorpus.commentFree(of: Self.file)
        #expect(source.contains(".help(L10n.string(\"sidebar.error.dismiss\""))
        #expect(source.contains(".accessibilityLabel(L10n.string(\"sidebar.error.dismiss\""))
    }
}
