import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit

@Suite("Branded window title")
@MainActor
struct WindowTitleViewTests {
    @Test(arguments: [ColorScheme.light, .dark], [CGFloat(180), 300])
    func rendersTheExistingLogoAndHandlesLongSessionNames(scheme: ColorScheme, width: CGFloat) throws {
        let icon = try #require(ApplicationIcon.load())
        #expect(icon.isValid)
        let preview = VStack(spacing: 16) {
            WindowTitleView(title: .newConnection)
            WindowTitleView(title: .named("production"))
            WindowTitleView(title: .named("production-europe-west / operations / database-primary"))
        }
        .frame(width: width, height: 140)
        .background(.background)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size == NSSize(width: width, height: 140))
    }

    @Test func nativeAndVisibleTitlesShareOneResolutionAndTheIconIsDecorative() throws {
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let owner = try SourceCorpus.code(of: root.appendingPathComponent("ContentView+Detail.swift"))
        let view = try SourceCorpus.code(of: root.appendingPathComponent("WindowTitleView.swift"))
        #expect(owner.contains("let title: TabTitle = showsSettingsWorkspace"))
        #expect(owner.contains(": tabTitle(for: activeTab)"))
        #expect(owner.contains(".navigationTitle(title.windowTitle)"))
        #expect(owner.contains(".toolbar(removing: .title)"))
        #expect(owner.contains("ToolbarItem(placement: .navigation)"))
        #expect(!owner.contains("ToolbarItem(placement: .principal)"))
        #expect(owner.contains("WindowTitleView(title: title)"))
        #expect(view.contains("private static let icon = ApplicationIcon.load()"))
        #expect(view.contains("Image(nsImage: icon)"))
        #expect(view.contains(".accessibilityHidden(true)"))
        #expect(view.contains(".accessibilityLabel(title.windowTitle)"))
        #expect(view.contains(".truncationMode(.middle)"))
    }
}
