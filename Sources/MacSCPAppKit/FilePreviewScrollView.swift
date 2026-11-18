import AppKit

/// The text view lays out one window. The sibling scroller measures the file
/// in bytes, using the visible share of the current window for the thumb size.
@MainActor
final class FilePreviewScrollView: NSScrollView {
    struct Window {
        let offset: UInt64
        let count: Int
        let size: UInt64
        let revision: Int
        let placement: Double
        let enabled: Bool
        let loading: Bool
    }

    var fileWindow: Window?
    var seek: ((Double, Double) -> Void)?
    var moveWindow: ((Bool) -> Void)?
    private let fileScroller = FilePreviewScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))

    func makeContainer() -> NSView {
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        fileScroller.scrollerStyle = .legacy
        fileScroller.target = self
        fileScroller.action = #selector(scrollFile(_:))
        fileScroller.trackingEnded = { [weak self] in self?.updateFileScroller() }

        let container = NSView()
        for child in [self, fileScroller] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topAnchor.constraint(equalTo: container.topAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            trailingAnchor.constraint(equalTo: fileScroller.leadingAnchor),
            fileScroller.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fileScroller.topAnchor.constraint(equalTo: container.topAnchor),
            fileScroller.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fileScroller.widthAnchor.constraint(equalToConstant: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        ])
        return container
    }

    private var maximumY: CGFloat { max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height) }

    private var visibleBytes: Double {
        let height = contentView.bounds.height
        let documentHeight = height + maximumY
        guard documentHeight > 0, let fileWindow else { return 0 }
        return Double(fileWindow.count) * Double(height / documentHeight)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateFileScroller()
    }

    func updateFileScroller() {
        guard let fileWindow, fileWindow.size > 0 else {
            fileScroller.isEnabled = false
            fileScroller.knobProportion = 1
            fileScroller.doubleValue = 0
            return
        }
        let totalBytes = Double(fileWindow.size)
        let visible = visibleBytes
        let fraction = maximumY > 0 ? Double(contentView.bounds.minY / maximumY) : 0
        let topByte = Double(fileWindow.offset) + fraction * (Double(fileWindow.count) - visible)
        fileScroller.knobProportion = visible / totalBytes
        fileScroller.isEnabled = fileWindow.enabled && visible < totalBytes
        if !fileScroller.isTracking && !fileWindow.loading {
            fileScroller.doubleValue = min(1, max(0, topByte / max(1, totalBytes - visible)))
        }
    }

    func placeWindow(at fraction: Double, horizontalOffset: CGFloat) {
        scroll(to: NSPoint(x: horizontalOffset, y: maximumY * fraction))
    }

    private func scroll(to point: NSPoint) {
        let bounds = NSRect(origin: point, size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    func seekFile(to fraction: Double) {
        guard let fileWindow, fileWindow.enabled else { return }
        if UInt64(fileWindow.count) == fileWindow.size {
            placeWindow(at: fraction, horizontalOffset: contentView.bounds.minX)
        } else {
            seek?(fraction, visibleBytes)
        }
    }

    @objc private func scrollFile(_ sender: NSScroller) {
        switch sender.hitPart {
        case .knob, .knobSlot, .noPart: seekFile(to: sender.doubleValue)
        case .incrementPage: scrollPageDown(sender)
        case .decrementPage: scrollPageUp(sender)
        case .incrementLine: scrollVertically(by: verticalLineScroll)
        case .decrementLine: scrollVertically(by: -verticalLineScroll)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        if !event.modifierFlags.contains(.shift), abs(dy) > abs(event.scrollingDeltaX),
           moveAtBoundary(forward: dy < 0) { return }
        super.scrollWheel(with: event)
    }

    override func scrollPageDown(_ sender: Any?) { scrollVertically(by: pageHeight) }
    override func scrollPageUp(_ sender: Any?) { scrollVertically(by: -pageHeight) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { seekFile(to: 0) }
    override func scrollToEndOfDocument(_ sender: Any?) { seekFile(to: 1) }

    private var pageHeight: CGFloat { max(verticalLineScroll, contentView.bounds.height - verticalPageScroll) }

    private func scrollVertically(by delta: CGFloat) {
        if moveAtBoundary(forward: delta > 0) { return }
        let origin = contentView.bounds.origin
        scroll(to: NSPoint(x: origin.x, y: origin.y + delta))
    }

    private func moveAtBoundary(forward: Bool) -> Bool {
        guard let fileWindow, fileWindow.enabled else { return false }
        let y = contentView.bounds.minY
        if forward {
            guard y >= maximumY - 0.5, fileWindow.offset + UInt64(fileWindow.count) < fileWindow.size else { return false }
        } else {
            guard y <= 0.5, fileWindow.offset > 0 else { return false }
        }
        moveWindow?(forward)
        return true
    }
}

@MainActor
private final class FilePreviewScroller: NSScroller {
    private(set) var isTracking = false
    var trackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event)
        isTracking = false
        trackingEnded?()
    }
}
