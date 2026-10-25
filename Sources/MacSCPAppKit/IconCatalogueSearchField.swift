import AppKit
import SwiftUI

/// Owns the popover's keyboard focus after its native window is attached.
/// SwiftUI's onAppear can precede that attachment and leave the editor behind
/// the popover active. Never look up an unrelated application's key window.
struct IconCatalogueSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        let title = L10n.string("appearance.search", "Search icons by name")
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.stringValue = text
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: SearchField, coordinator: Coordinator) {
        field.endInitialFocusRequest()
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: IconCatalogueSearchField
        init(_ parent: IconCatalogueSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Searching must not activate the underlying editor's Save button.
            commandSelector == #selector(NSResponder.insertNewline(_:))
        }
    }

    final class SearchField: NSSearchField {
        private var focusRequest = UUID()
        private var acquiredInitialFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            endInitialFocusRequest()
            acquiredInitialFocus = false
            guard let window else { return }
            window.initialFirstResponder = self
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
            requestInitialFocus()
        }

        func endInitialFocusRequest() {
            focusRequest = UUID()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        }

        @objc private func windowBecameKey(_ notification: Notification) { requestInitialFocus() }

        private func requestInitialFocus() {
            let request = focusRequest
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.focusRequest == request, !self.acquiredInitialFocus else { return }
                // Only the popover window containing this field may take focus.
                window.makeKey()
                if window.makeFirstResponder(self), window.isKeyWindow {
                    self.acquiredInitialFocus = true
                }
            }
        }
    }
}
