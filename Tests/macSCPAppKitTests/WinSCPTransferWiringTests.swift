import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("WinSCP transfer presentation")
struct WinSCPTransferWiringTests {
    @Test func unifiedCommandsRouteToTheWindowScopedFormatSheets() throws {
        func code(_ file: String) throws -> String {
            try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/" + file))
        }
        let menu = try code("MacSCPCommands.swift")
        let lifecycle = try code("ContentView+Lifecycle.swift")
        let sheets = try code("ContentView+Sheets.swift")
        let transfer = try code("ContentView+ExportImport.swift")
        let export = try code("SessionTransferExportSheet.swift")
        #expect(menu.contains("tabCommands?.importSessions?()"))
        #expect(menu.contains("tabCommands?.exportAllSessions?()"))
        #expect(!menu.contains("tabCommands?.importWinSCP?()"))
        #expect(!menu.contains("tabCommands?.exportWinSCP?()"))
        #expect(lifecycle.contains("tabCommands.importWinSCP ="))
        #expect(lifecycle.contains("tabCommands.exportWinSCP ="))
        #expect(sheets.contains("WinSCPTransferSheet(action:"))
        #expect(transfer.contains("SessionImportDetection.detect(data)"))
        #expect(transfer.contains("winSCPTransferAction = .importFile"))
        #expect(export.contains("WinSCPTransferSheet(action: .exportFile"))
        #expect(export.contains("exportSessionIDs: scopedIDs"))
        #expect(sheets.contains("await applyImport(PendingSessionImport(payload:"))
    }

    @Test func cancelledCryptoWorkDoesNotReturnASuccess() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WinSCPBackgroundWork.run {
                // The operation cooperates even if it started before cancellation.
                try Task.checkCancellation()
                return true
            }
        }
        switch await task.result {
        case .success: Issue.record("Cancelled work returned a result")
        case .failure(let error): #expect(error is CancellationError)
        }
    }
}
