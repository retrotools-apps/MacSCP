import AppKit
import SwiftUI

/// SwiftUI ignores idealWidth when reinserting a pane into an existing
/// HSplitView. Restore its native divider once after mounting, then leave all
/// subsequent dragging and window resizing to AppKit.
struct SidebarDividerRestorer: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.width = width
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var width: CGFloat = 0
        private var restored = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRestore()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleRestore()
        }
        private func scheduleRestore() {
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }
        private func restore() {
            guard !restored, window != nil, width > 0 else { return }
            var ancestor = superview
            while let current = ancestor {
                if let split = current as? NSSplitView, split.isVertical {
                    guard split.arrangedSubviews.count >= 2 else { return }
                    restored = true
                    split.setPosition(width, ofDividerAt: 0)
                    return
                }
                ancestor = current.superview
            }
        }
    }
}
