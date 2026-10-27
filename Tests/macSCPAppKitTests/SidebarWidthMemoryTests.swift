import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit

@MainActor
struct SidebarWidthMemoryTests {
    @Observable class Model {
        var visible = true
        var openingWidth: CGFloat = 220
    }
    private struct Fixture: View {
        @Bindable var model: Model
        var body: some View {
            HSplitView {
                if model.visible {
                    Color.clear.frame(minWidth: 170, idealWidth: model.openingWidth, maxWidth: 340)
                        .background { GeometryReader { proxy in
                            Color.clear.preference(key: SidebarMeasuredWidthKey.self, value: proxy.size.width)
                        } }
                        .background { SidebarDividerRestorer(width: model.openingWidth) }
                }
                Color.clear.frame(minWidth: 500, maxWidth: .infinity)
            }
            .modifier(SidebarWidthMemory(visible: model.visible, openingWidth: $model.openingWidth))
        }
    }
    private func split(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { split(in: $0) }.first
    }
    /// Wait for native layout outcomes rather than assuming AppKit has mounted
    /// a split view after a fixed delay while the rest of the suite is busy.
    private func waitForLayout(_ host: NSView, until ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready(), "Native split layout did not reach the expected state")
    }

    @Test func draggedWidthSurvivesRepeatedHideAndShow() async throws {
        let model = Model()
        let host = NSHostingView(rootView: Fixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1200, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await waitForLayout(host) {
            guard let native = split(in: host), native.arrangedSubviews.count == 2 else { return false }
            return abs(native.arrangedSubviews[0].frame.width - model.openingWidth) <= 1
        }
        let native = try #require(split(in: host))
        native.setPosition(310, ofDividerAt: 0)
        try await waitForLayout(host) {
            abs(native.arrangedSubviews[0].frame.width - 310) <= 1
        }
        // Let the geometry preference deliver the divider measurement before
        // testing the independent visibility transition.
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let dragged = try #require(native.arrangedSubviews.first).frame.width
        #expect(abs(dragged - 310) <= 1)
        for _ in 0..<3 {
            model.visible = false
            try await waitForLayout(host) { split(in: host)?.arrangedSubviews.count == 1 }
            #expect(abs(model.openingWidth - dragged) <= 1)
            model.visible = true
            try await waitForLayout(host) {
                guard let current = split(in: host), current.arrangedSubviews.count == 2 else { return false }
                return abs(current.arrangedSubviews[0].frame.width - dragged) <= 1
            }
            let current = try #require(split(in: host))
            let restored = try #require(current.arrangedSubviews.first).frame.width
            #expect(abs(restored - dragged) <= 1)
        }
    }
}
