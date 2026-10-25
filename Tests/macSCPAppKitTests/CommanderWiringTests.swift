import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore
@testable import MacSCPAppKit

@Suite("Commander action and protection wiring")
struct CommanderWiringTests {
    @Test func navigationAndActionStripFollowTheRequestedCommanderLayout() throws {
        let pane = try SourceCorpus.commentFree(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/BrowserPane.swift"))
        #expect(pane.contains("commanderButton(.rename"))
        #expect(!pane.contains("commanderButton(.delete"))
        #expect(pane.contains("case .delete: deleteRequest = selection"))
        #expect(pane.contains("DirectorySizeCalculator.totalBytes(of: target, on: fileSystem)"))
        let path = try SourceCorpus.commentFree(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/PathBar.swift"))
        #expect(path.contains(".defaultScrollAnchor(.leading)"))
        #expect(!path.contains(".defaultScrollAnchor(.trailing)"))
        let table = try SourceCorpus.commentFree(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/RemoteFileTableView.swift"))
        #expect(table.contains("case \"r\": key = .commandR"))
        #expect(table.contains("systemSymbolName: \"arrow.up.folder\""))
    }
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func paneActionsUseTheExistingSelectionAndDestinationRules() throws {
        let source = try SourceCorpus.text(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/BrowserPane.swift"))
        #expect(source.contains("private var commanderEntries: [BrowserMenuEntry]"))
        #expect(source.contains("BrowserContextMenu.entries(for: viewModel.selectedItems, side: side"))
        #expect(source.contains("destination: destinationScope?() ?? .ordinary"))
        #expect(source.contains("guard viewModel.state == .loaded, commanderEntries.contains(entry) else { return }"))
        #expect(source.contains("case .delete: deleteRequest = selection"))
        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(source.contains("onActivatePane?()"))
    }

    @Test func protectionRequiresExplicitConfirmationAndOffMainActorMigration() throws {
        let source = try SourceCorpus.text(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/CredentialSettingsSection.swift"))
        #expect(source.contains("struct CredentialSettingsSection: View"))
        #expect(source.contains("CredentialProtection.hasSignedKeychainIdentity"))
        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains("Task.detached(priority: .userInitiated)"))
        #expect(source.contains("case .enable: return try CredentialProtection.enable()"))
        #expect(source.contains("case .disable: return try CredentialProtection.disable()"))
        #expect(!source.contains(".onAppear"))
    }
}
