import AppKit
import Foundation
import macSCPCore

/// The packaged app and `swift run` use the same generated icon. A bare SwiftPM
/// executable has no main-bundle icon, so AppKit must install it explicitly.
@MainActor
enum ApplicationIcon {
    static func load() -> NSImage? {
        guard let url = L10n.bundle.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func install() {
        if let image = load() {
            NSApplication.shared.applicationIconImage = image
        }
    }

    /// The same foreground geometry as the application icon, without its
    /// background. A template lets macOS supply the menu bar's native tint.
    static func menuBarImage() -> NSImage? {
        guard let url = L10n.bundle.url(forResource: "MenuBarIcon", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    static func tintedMenuBarImage(_ color: NSColor) -> NSImage? {
        guard let source = menuBarImage() else { return nil }
        let image = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

enum TunnelMenuSummary {
    enum Tone: Equatable { case neutral, healthy, warning }
    static func tone(states: [TunnelState]) -> Tone {
        if states.contains(where: {
            switch $0 {
            case .failed, .needsConfirmation, .reconnecting, .connecting: true
            case .active: $0.isDegraded
            case .stopped: false
            }
        }) { return .warning }
        return states.contains { if case .active = $0 { true } else { false } } ? .healthy : .neutral
    }
}
