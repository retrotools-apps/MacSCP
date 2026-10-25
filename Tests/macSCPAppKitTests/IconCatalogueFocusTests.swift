import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit

@MainActor
@Suite("Icon catalogue keyboard focus", .serialized)
struct IconCatalogueFocusTests {
    private func drainMainQueue() async throws {
        try await awaitResumption { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func typingInThePopoverDoesNotReplaceTheSelectedTunnelName() async throws {
        _ = NSApplication.shared
        let editor = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        let popover = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        popover.isReleasedWhenClosed = false
        defer { popover.close(); editor.close() }
        let name = NSTextField(string: "Protected tunnel")
        editor.contentView = name
        editor.makeKeyAndOrderFront(nil)
        name.selectText(nil)
        var query = ""
        let search = IconCatalogueSearchField.SearchField()
        let coordinator = IconCatalogueSearchField.Coordinator(.init(text: Binding(get: { query }, set: { query = $0 })))
        search.delegate = coordinator
        popover.contentView = search
        editor.addChildWindow(popover, ordered: .above)
        popover.orderFront(nil)
        try await drainMainQueue()
        let fieldEditor = try #require(search.currentEditor())
        #expect(popover.firstResponder === fieldEditor)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: popover.windowNumber, context: nil,
            characters: "dns", charactersIgnoringModifiers: "dns", isARepeat: false, keyCode: 2))
        popover.sendEvent(event)
        #expect(search.stringValue == "dns")
        #expect(query == "dns")
        #expect(name.stringValue == "Protected tunnel")
        search.endInitialFocusRequest()
    }

    @Test func aDetachedSearchFieldCannotStealFocusLater() async throws {
        let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let container = NSView()
        panel.contentView = container
        let search = IconCatalogueSearchField.SearchField()
        container.addSubview(search)
        search.removeFromSuperview()
        try await drainMainQueue()
        #expect(search.currentEditor() == nil)
        #expect(panel.firstResponder !== search)
    }
}
