import Foundation
import SwiftUI
import Testing
import MacSCPTestSupport
@testable import MacSCPAppKit

@Suite("Window menu")
@MainActor
struct WindowMenuTests {
    @Test func onlyExistingTabsGetNamesAndOnlyTheFirstNineHaveShortcuts() {
        let items = (0..<12).map { index in
            WindowTabMenuItem(id: UUID(), title: "Server \(index)", index: index, isSelected: index == 2)
        }
        #expect(items.filter(\.isSelected).map(\.title) == ["Server 2"])
        #expect(items.prefix(9).allSatisfy { $0.shortcut != nil })
        #expect(items.suffix(3).allSatisfy { $0.shortcut == nil })
        #expect(items[0].shortcut?.key == KeyEquivalent("1"))
        #expect(items[8].shortcut?.key == KeyEquivalent("9"))
        #expect(items[0].shortcut?.modifiers == .command)
    }

    @Test func previousAndNextWrapInTheFocusedWindowOnly() {
        let first = TabCommands()
        let other = TabCommands()
        first.windowTabs = [
            .init(id: UUID(), title: "Alpha", index: 0, isSelected: true),
            .init(id: UUID(), title: "Beta", index: 1, isSelected: false)
        ]
        other.windowTabs = [.init(id: UUID(), title: "Other window", index: 0, isSelected: true)]
        var selected: [Int] = []
        first.selectTab = { selected.append($0) }
        other.selectTab = { _ in Issue.record("Must not target a different window") }
        first.selectAdjacentTab(by: -1)
        first.selectAdjacentTab(by: 1)
        #expect(selected == [1, 1])
        other.selectAdjacentTab(by: 1)
        #expect(selected == [1, 1])
    }

    @Test func anEmptyOrStaleSnapshotCannotCycle() {
        let commands = TabCommands()
        commands.selectTab = { _ in Issue.record("No selected tab exists") }
        commands.selectAdjacentTab(by: 1)
        commands.windowTabs = [
            .init(id: UUID(), title: "Alpha", index: 0, isSelected: false),
            .init(id: UUID(), title: "Beta", index: 1, isSelected: false)
        ]
        commands.selectAdjacentTab(by: -1)
    }

    @Test func menusUseWindowSnapshotsAndDisableUnroutableActions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try SourceCorpus.commentFree(of: root.appendingPathComponent("Sources/MacSCPAppKit/MacSCPCommands.swift"))
        #expect(source.contains("ForEach(tabCommands.windowTabs)"))
        #expect(source.contains("get: { item.isSelected }"))
        #expect(source.contains(".keyboardShortcut(item.shortcut)"))
        #expect(!source.contains("ForEach(1...9"))
        #expect(source.contains("CommandGroup(after: .windowArrangement)"))
        #expect(source.contains("CommandGroup(replacing: .help)"))
        let functions = ["newTab", "showKnownHosts", "showServerCertificates", "showLogins", "showSSHKeys",
                         "showAdHocAuditLog", "exportAllSessions", "importSessions", "showKeyboardShortcuts", "showWhatsNew"]
        for function in functions {
            let anchor = "tabCommands?.\(function)?()"
            let range = try #require(source.range(of: anchor))
            let tail = source[range.upperBound...].prefix(200)
            #expect(tail.contains(".disabled(tabCommands == nil)"), "\(function) must disable when its focused bridge is absent")
        }
        let app = try SourceCorpus.commentFree(of: root.appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift"))
        #expect(app.contains("NSWindow.allowsAutomaticWindowTabbing = false"))
        let chrome = try SourceCorpus.commentFree(of: root.appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift"))
        #expect(chrome.contains(".tabbingMode = .disallowed"))
        let startup = try SourceCorpus.commentFree(of: root.appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift"))
        #expect(startup.contains("struct StartupSettingsSection"))
        #expect(startup.contains("TunnelAutostartSheet("))
        #expect(!source.contains("tunnel.menu.autostart"))
    }
}
