import AppKit
import Foundation
import MacSCPTestSupport
import Observation
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Regression coverage for replacing the former standalone Settings window.
@Suite("Main-window Settings workspace")
@MainActor
struct SettingsWorkspaceTests {
    @Test func dataManagementKeepsCurrentManagersWithoutAnInlineDestructiveCleanup() throws {
        let settings = try code("SettingsView.swift")
        let management = try #require(SourceSpan.body(after: "private struct ManageDataSettingsSection: View", in: settings))
        #expect(management.contains("SSHKeysSheet()"))
        #expect(management.contains("KnownHostsSheet(store:"))
        #expect(management.contains("settingsBridge.showLoginsFromSettings?()"))
        #expect(!management.contains(".confirmationDialog("))
    }

    @Test func themedNavigationContainsEverySectionExactlyOnceAndSharesTheWorkspaceHeading() throws {
        #expect(SettingsNavigationGroup.allCases == [.application, .workflow, .protocols, .maintenance])
        let sections = SettingsNavigationGroup.allCases.flatMap(\.sections)
        #expect(sections.count == 12)
        #expect(Set(sections).count == sections.count)
        #expect(SettingsNavigationGroup.application.sections == [.general, .startup, .security, .appearance])
        #expect(SettingsNavigationGroup.workflow.sections == [.transfers, .openWith, .terminal, .shortcuts])
        #expect(SettingsNavigationGroup.protocols.sections == [.ssh, .s3])
        #expect(SettingsNavigationGroup.maintenance.sections == [.manageData, .whatsNew])
        let shared = try code("SidebarList.swift")
        #expect(shared.contains("struct SidebarWorkspaceHeading: View"))
        #expect(shared.contains(".padding(.top, 14)"))
        for file in ["SessionSidebar.swift", "TunnelWorkspaceSidebar.swift", "SettingsView.swift"] {
            #expect(try code(file).contains("SidebarWorkspaceHeading(title:"))
        }
    }

    @Test func allWorkspacesShareNavigationLabelsAndTunnelCreationLivesInTheSidebar() throws {
        let content = try code("ContentView.swift")
        #expect(content.contains(".environment(\\.groupColorsEnabled, settingsStore.groupColorsEnabled)"))
        #expect(try code("SettingsView.swift").contains("isOn: $store.groupColorsEnabled"))
        let label = try code("SidebarList.swift")
        #expect(label.contains("struct SidebarNavigationLabel: View"))
        #expect(label.contains(".frame(minHeight: 24)"))
        for file in ["SettingsView.swift", "SessionSidebar.swift", "TunnelWorkspaceSidebar.swift"] {
            #expect(try code(file).contains("SidebarNavigationLabel(title:"))
        }
        let sidebar = try code("TunnelWorkspaceSidebar.swift")
        #expect(sidebar.contains("onNewTunnel()"))
        #expect(sidebar.contains(".contextMenu {"))
        #expect(sidebar.contains("editingGroup = GroupEditorItem(group: nil)"))
        let workspace = try code("TunnelWorkspaceView.swift")
        let header = try #require(SourceSpan.body(after: "private var header: some View", in: workspace))
        #expect(header.contains("Label(startTitle"))
        #expect(!header.contains("tunnels.new"))
        #expect(workspace.contains("requestsNewTunnel.wrappedValue = false"))
        #expect(workspace.contains("GroupTintStyle.tunnelRowOpacity("))
        #expect(workspace.contains("TunnelGroupAccent(hue:"))
        #expect(!workspace.contains("GroupContentTint(hue:"))
        let cards = try code("SessionGroupOverviewView.swift")
        #expect(cards.contains("groupHue: session.groupID.flatMap { hues[$0] }"))
        #expect(cards.contains("GroupContentTint(hue: card.groupHue, darkerNeutral: card.darkerNeutral, customColor: card.groupColor)"))
    }

    private static let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
    private func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: Self.root.appendingPathComponent(name))
    }

    @Observable final class Navigation {
        var workspace = 0
    }

    private struct SharedSplitHarness: View {
        @Bindable var navigation: Navigation
        var body: some View {
            HSplitView {
                ZStack {
                    SettingsSidebarView(selection: .constant(.general), onSessions: {}, onTunnels: {})
                        .opacity(navigation.workspace == 2 ? 1 : 0)
                    Color.clear.opacity(navigation.workspace == 1 ? 1 : 0)
                    Color.clear.opacity(navigation.workspace == 0 ? 1 : 0)
                }
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 400)
                Color.clear.frame(minWidth: 500, maxWidth: .infinity)
            }
        }
    }

    @Test func resizingTheSharedSplitSurvivesEveryWorkspaceSwitch() async throws {
        _ = NSApplication.shared
        let navigation = Navigation()
        let host = NSHostingView(rootView: SharedSplitHarness(navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func split(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { split(in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let divider = try #require(split(in: host))
        divider.setPosition(285, ofDividerAt: 0)
        let width = try #require(divider.subviews.first).frame.width
        #expect(abs(width - 285) < 2)
        for workspace in [1, 2, 0, 2, 1, 0] {
            navigation.workspace = workspace
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let current = try #require(split(in: host))
            #expect(current === divider)
            #expect(abs(try #require(current.subviews.first).frame.width - width) < 2)
        }
    }

    @Test func settingsIsAWorkspaceAndCannotOverwriteTheMainWindowFrame() throws {
        let app = try code("MacSCPApp.swift"), settings = try code("SettingsView.swift")
        #expect(app.contains("WindowGroup("))
        #expect(!app.contains("Settings {"))
        #expect(settings.contains("struct SettingsSidebarView: View"))
        #expect(!settings.contains("HSplitView"))
        #expect(!settings.contains("WindowAccessor"))
        #expect(!settings.contains("setFrameAutosaveName("))
        #expect(!settings.contains("contentMinSize"))
        let workspace = try code("SettingsWorkspaceView.swift")
        #expect(workspace.contains("SettingsView("))
        #expect(workspace.contains(".onExitCommand(perform: onClose)"))
        #expect(!workspace.contains("onBack"))
        #expect(settings.contains("SessionSidebarToolbar(showsSettings: true"))
        let detail = try code("ContentView+Detail.swift")
        let split = try #require(SourceSpan.body(after: "var splitLayout: some View", in: detail))
        #expect(split.contains("HSplitView {"))
        #expect(split.contains("SettingsSidebarView(selection: $settingsSection"))
        #expect(split.contains("ZStack {"))
        #expect(split.contains(".allowsHitTesting(showsSettingsWorkspace)"))
        #expect(split.contains("idealWidth: sidebarOpeningWidth"))
        #expect(split.contains("value: proxy.size.width"))
    }

    @Test func openingSettingsKeepsConnectionWorkspacesAndProbesMounted() throws {
        let detail = try code("ContentView+Detail.swift")
        #expect(detail.contains("SettingsWorkspaceView("))
        #expect(detail.contains(".opacity(showsSettingsWorkspace ? 0 : 1)"))
        #expect(detail.contains(".allowsHitTesting(!showsSettingsWorkspace)"))
        #expect(detail.contains("LivenessProbeRunner("))
        let commands = try code("MacSCPCommands.swift")
        #expect(commands.contains("CommandGroup(replacing: .appSettings)"))
        #expect(commands.contains("tabCommands?.showSettings"))
        let lifecycle = try code("ContentView+Lifecycle.swift")
        #expect(lifecycle.contains("tabCommands.showSettings = { showsSettingsWorkspace = true }"))
        let close = try #require(SourceSpan.body(after: "func handleCloseActiveTabCommand()", in: lifecycle))
        #expect(close.contains("if showsSettingsWorkspace"))
        let back = try #require(close.range(of: "showsSettingsWorkspace = false"))
        let tabClose = try #require(close.range(of: "requestClose(tab)"))
        #expect(back.lowerBound < tabClose.lowerBound)
    }

    @Test func loginItemBelongsToStartupSettingsNotTunnelNavigation() throws {
        let settings = try code("SettingsView.swift"), tunnels = try code("TunnelWorkspaceSidebar.swift")
        let startup = try #require(SourceSpan.body(after: "private struct StartupSettingsSection: View", in: settings))
        #expect(startup.contains("LoginItemModel()"))
        #expect(startup.contains("loginItem.setEnabled"))
        #expect(tunnels.contains("struct TunnelWorkspaceSidebar: View"))
        #expect(!tunnels.contains("LoginItemModel()"))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func workspaceRendersInsideAnExistingWindowWithoutChangingItsSizeOrAutosaveName(scheme: ColorScheme) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = HSplitView {
            SettingsSidebarView(selection: .constant(.general), onSessions: {}, onTunnels: {})
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 400)
            SettingsWorkspaceView(store: SettingsStore(directory: directory),
                launchLanguage: .system, settingsBridge: SettingsWindowBridge(),
                selection: .constant(.general), onClose: {})
        }
            .frame(width: 1000, height: 650).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        #expect(try #require(renderer.nsImage).isValid)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        let before = window.frame
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(window.frame.size == before.size)
        #expect(window.frameAutosaveName.isEmpty)
    }
}
