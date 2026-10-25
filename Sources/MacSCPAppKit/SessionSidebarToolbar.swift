import AppKit
import SwiftUI

/// Shared folder typography for the Sessions and Tunnels navigation trees.
struct SidebarGroupTitle: View {
    let name: String
    var body: some View {
        Text(name).textCase(.uppercase)
            .font(.system(size: 10.5, weight: .semibold)).tracking(1.0)
            .foregroundStyle(DesignTokens.inkTertiary)
            .lineLimit(1).truncationMode(.tail)
    }
}

@MainActor
enum TunnelSymbols {
    nonisolated static let tunnel = "apple.health.trends"
    static let image = makeImage(preferredImage: NSImage(systemSymbolName: tunnel, accessibilityDescription: nil))

    /// Some macOS symbol catalogs do not contain apple.health.trends. Keep
    /// a template fallback with the same three diverging arrows.
    static func makeImage(preferredImage: NSImage?) -> NSImage {
        if let preferredImage { return preferredImage }
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            NSColor.black.setStroke()
            let arrows = NSBezierPath()
            arrows.move(to: NSPoint(x: 4, y: 16))
            arrows.line(to: NSPoint(x: 24, y: 16))
            arrows.move(to: NSPoint(x: 4, y: 20))
            arrows.curve(to: NSPoint(x: 26, y: 28),
                         controlPoint1: NSPoint(x: 14, y: 20),
                         controlPoint2: NSPoint(x: 21, y: 23))
            arrows.move(to: NSPoint(x: 4, y: 12))
            arrows.curve(to: NSPoint(x: 26, y: 4),
                         controlPoint1: NSPoint(x: 14, y: 12),
                         controlPoint2: NSPoint(x: 21, y: 9))
            arrows.lineWidth = 2.8
            arrows.lineCapStyle = .round
            arrows.stroke()
            NSColor.black.setFill()
            for points in [
                [NSPoint(x: 29, y: 16), NSPoint(x: 23, y: 20), NSPoint(x: 23, y: 12)],
                [NSPoint(x: 28, y: 30), NSPoint(x: 21, y: 28), NSPoint(x: 26, y: 23)],
                [NSPoint(x: 28, y: 2), NSPoint(x: 26, y: 9), NSPoint(x: 21, y: 4)]
            ] {
                let head = NSBezierPath()
                head.move(to: points[0])
                head.line(to: points[1])
                head.line(to: points[2])
                head.close()
                head.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct TunnelIcon: View {
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: TunnelSymbols.image).renderingMode(.template)
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Fixed sidebar actions, outside the scrolling session list and its
/// connection-attempt interaction gate. Settings navigation stays window-local.
struct SessionSidebarToolbar: View {
    var showsTunnels = false
    var showsSettings = false
    var navigationDisabled = false
    var onSessions: () -> Void = {}
    var onTunnels: () -> Void = {}
    var onSettings: () -> Void = {}
    var groupsAvailable = false
    var onCollapseGroups: (() -> Void)? = nil
    var onExpandGroups: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Button(action: onSessions) {
                    Label(L10n.string("workspace.sessions", "Sessions"), systemImage: "rectangle.stack")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .help(L10n.string("workspace.sessions", "Sessions"))
                .foregroundStyle(!showsTunnels && !showsSettings ? Color.accentColor : Color.secondary)
                .disabled(navigationDisabled)
                Button(action: onTunnels) {
                    Label { Text(L10n.string("workspace.tunnels", "Tunnels")) } icon: { TunnelIcon() }
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .help(L10n.string("workspace.tunnels", "Tunnels"))
                .foregroundStyle(showsTunnels && !showsSettings ? Color.accentColor : Color.secondary)
                .disabled(navigationDisabled)
                Button(action: onSettings) {
                    Label(L10n.string("sidebar.settings", "Settings"), systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("sidebar.settings", "Settings"))
                .foregroundStyle(showsSettings ? Color.accentColor : Color.secondary)
                Spacer(minLength: 0)
                if let onCollapseGroups, let onExpandGroups {
                    Button(action: onCollapseGroups) {
                        Label { L10n.text("sidebar.groups.collapseAll", "Collapse group contents") } icon: {
                            SidebarGroupActionIcon(action: .collapse)
                        }
                            .labelStyle(.iconOnly)
                            .frame(width: 28, height: 28)
                    }
                    .help(L10n.string("sidebar.groups.collapseAll", "Collapse group contents"))
                    .disabled(!groupsAvailable || navigationDisabled)
                    Button(action: onExpandGroups) {
                        Label { L10n.text("sidebar.groups.expandAll", "Expand all groups") } icon: {
                            SidebarGroupActionIcon(action: .expand)
                        }
                            .labelStyle(.iconOnly)
                            .frame(width: 28, height: 28)
                    }
                    .help(L10n.string("sidebar.groups.expandAll", "Expand all groups"))
                    .disabled(!groupsAvailable || navigationDisabled)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
