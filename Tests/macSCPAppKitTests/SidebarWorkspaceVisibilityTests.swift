import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit

@MainActor
struct SidebarWorkspaceVisibilityTests {
    @Observable class Navigation {
        var selected = 0
        var dark = false
    }

    final class TooltipView: NSView {
        var workspace = 0
        var identity = UUID()
        var dark = false
        var highContrast = false
        override var acceptsFirstResponder: Bool { true }
    }

    private struct TooltipProbe: NSViewRepresentable {
        let workspace: Int
        let identity: UUID
        func makeNSView(context: Context) -> TooltipView { TooltipView() }
        func updateNSView(_ view: TooltipView, context: Context) {
            view.workspace = workspace
            view.identity = identity
            view.dark = context.environment.colorScheme == .dark
            view.highContrast = context.environment.highContrast
            view.toolTip = "Workspace \(workspace) tooltip"
        }
    }

    private struct Workspace: View {
        let number: Int
        @State private var identity = UUID()
        var body: some View {
            List {
                TooltipProbe(workspace: number, identity: identity).frame(height: 40)
            }
        }
    }

    private struct Fixture: View {
        @Bindable var navigation: Navigation
        var body: some View {
            ZStack {
                Workspace(number: 0).modifier(SidebarWorkspaceVisibility(isVisible: navigation.selected == 0))
                Workspace(number: 1).modifier(SidebarWorkspaceVisibility(isVisible: navigation.selected == 1))
                Workspace(number: 2).modifier(SidebarWorkspaceVisibility(isVisible: navigation.selected == 2))
            }
            .environment(\.highContrast, true)
            .environment(\.colorScheme, navigation.dark ? .dark : .light)
        }
    }

    private func probes(in view: NSView) -> [TooltipView] {
        if let probe = view as? TooltipView { return [probe] }
        return view.subviews.flatMap { probes(in: $0) }
    }

    private func waitForLayout(_ host: NSView, until ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready(), "Native workspace did not reach its expected visibility")
    }

    @Test func hiddenWorkspacesCannotProvideTooltipsAndKeepTheirState() async throws {
        _ = NSApplication.shared
        let navigation = Navigation()
        let host = NSHostingView(rootView: Fixture(navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        var identities: [Int: UUID] = [:]
        var oldResponder: TooltipView?
        for selected in [0, 1, 2, 0, 2, 1, 0] {
            navigation.selected = selected
            navigation.dark.toggle()
            try await waitForLayout(host) {
                probes(in: host).contains {
                    $0.workspace == selected && !$0.isHiddenOrHasHiddenAncestor
                        && !$0.visibleRect.isEmpty && $0.dark == navigation.dark
                }
            }
            let current = try #require(probes(in: host).first {
                $0.workspace == selected && !$0.isHiddenOrHasHiddenAncestor
            })
            #expect(current.highContrast)
            #expect(current.dark == navigation.dark)
            navigation.dark.toggle()
            try await waitForLayout(host) { current.dark == navigation.dark }
            #expect(current.dark == navigation.dark)
            #expect(current.toolTip == "Workspace \(selected) tooltip")
            if let identity = identities[selected] { #expect(current.identity == identity) }
            identities[selected] = current.identity
            for inactive in probes(in: host) where inactive.workspace != selected {
                #expect(inactive.isHiddenOrHasHiddenAncestor)
                let scroll = try #require(inactive.enclosingScrollView)
                #expect(scroll.isHiddenOrHasHiddenAncestor)
                #expect(inactive.visibleRect.isEmpty)
            }
            if let oldResponder { #expect(window.firstResponder !== oldResponder) }
            #expect(window.makeFirstResponder(current))
            oldResponder = current
        }
        #expect(identities.count == 3)
    }

    @Test func allSidebarLayersUseNativeVisibility() throws {
        let source = try SourceCorpus.code(of: SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ContentView+Detail.swift"))
        let split = try #require(SourceSpan.body(after: "var splitLayout: some View", in: source))
        for condition in ["showsSettingsWorkspace", "showsTunnelWorkspace && !showsSettingsWorkspace", "!showsTunnelWorkspace && !showsSettingsWorkspace"] {
            #expect(split.contains("SidebarWorkspaceVisibility(isVisible: \(condition))"))
        }
        #expect(split.contains("SettingsSidebarView("))
        #expect(split.contains("TunnelWorkspaceSidebar("))
        #expect(split.contains("SessionSidebar("))
        #expect(!split.contains(".opacity(showsSettingsWorkspace ? 1 : 0)"))
    }
}
