import AppKit
import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Saved-session sidebar and development icon")
struct SessionSidebarSimplificationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func sidebarShowsSavedSessionsWithoutSearchOrAutomaticImports() throws {
        let source = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift"))
        #expect(source.contains("struct SessionSidebar: View"))
        #expect(source.contains("SidebarVisibility.compute("))
        #expect(source.contains("importedHostsCount: 0"))
        #expect(source.contains("search: nil"))
        #expect(source.contains("rows(under: nil, visibility: visibility)"))
        for removed in ["SheetSearchField(", "searchText", "searchIsRegex", "importedSection", "selectImported(", "hiddenImportsMenuTitle("] {
            #expect(!source.contains(removed))
        }
    }

    @Test func obsoleteHiddenImportManagementIsNotOffered() throws {
        let commands = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/MacSCPCommands.swift"))
        let settings = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift"))
        #expect(commands.contains("struct MacSCPCommands"))
        #expect(settings.contains("struct SettingsView"))
        #expect(!commands.contains("hiddenImportsMenuTitle("))
        #expect(!settings.contains("showHiddenImportsFromSettings?()"))
    }

    @Test @MainActor func theDevelopmentResourceContainsTheGeneratedApplicationIcon() throws {
        let image = try #require(ApplicationIcon.load())
        #expect(image.isValid)
        #expect(image.size.width > 0)
        let packaged = try Data(contentsOf: Self.root.appendingPathComponent("Resources/AppIcon.icns"))
        let development = try Data(contentsOf: Self.root.appendingPathComponent("Sources/MacSCPAppKit/Resources/AppIcon.icns"))
        #expect(packaged == development)
    }

    @Test func startupInstallsTheIconForBareExecutableLaunches() throws {
        let source = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift"))
        #expect(source.contains("NSApplication.shared.setActivationPolicy(.regular)"))
        #expect(source.contains("ApplicationIcon.install()"))
    }

    @Test func fixedBottomToolbarRoutesIntoTheMainWindowSettingsPage() throws {
        let sidebar = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift"))
        let toolbar = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/SessionSidebarToolbar.swift"))
        let toolbarLabels = try SourceCorpus.commentFree(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/SessionSidebarToolbar.swift"))
        let app = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift"))
        #expect(sidebar.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(sidebar.contains("SessionSidebarToolbar(navigationDisabled: interactionsDisabled, onTunnels: onShowTunnels, onSettings: onShowSettings,"))
        let interactionGate = try #require(sidebar.range(of: ".disabled(interactionsDisabled)"))
        let footer = try #require(sidebar.range(of: ".safeAreaInset(edge: .bottom"))
        #expect(interactionGate.upperBound < footer.lowerBound)
        #expect(toolbar.contains("Button(action: onSettings)"))
        #expect(toolbarLabels.contains("systemImage: \"gearshape\""))
        #expect(toolbar.contains(".labelStyle(.iconOnly)"))
        #expect(toolbarLabels.contains(".help(L10n.string(\"sidebar.settings\""))
        #expect(app.contains("WindowGroup("))
        #expect(!app.contains("Settings {"))
    }

    @Test @MainActor func settingsIconLabelIsLocalized() throws {
        for locale in ["en", "fr", "de", "pl"] {
            let path = try #require(L10n.bundle.path(forResource: locale, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            #expect(bundle.localizedString(forKey: "sidebar.settings", value: "MISSING", table: nil) != "MISSING")
        }
    }
}
