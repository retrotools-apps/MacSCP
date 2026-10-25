import SwiftUI
import macSCPCore

/// A compact saved identity, with connection health kept separate from its tint.
struct SessionSidebarIdentity: View {
    let appearance: SessionAppearance
    let kind: ConnectionKind
    let isConnected: Bool

    var showsConfiguredIcon: Bool {
        appearance.icon != .automatic
            || appearance.applicationLogo.flatMap { ApplicationLogo.record(id: $0) } != nil
    }

    var body: some View {
        Group {
            if showsConfiguredIcon {
                AppearanceIcon(icon: appearance.icon, applicationLogo: appearance.applicationLogo, kind: kind, size: 14)
                    .foregroundStyle(appearance.tint.color)
                    .overlay(alignment: .bottomTrailing) {
                        if isConnected {
                            Circle().fill(DesignTokens.statusPhosphor)
                                .frame(width: 4, height: 4)
                                .background(Circle().fill(.background).padding(-1))
                                .offset(x: 2, y: 1)
                        }
                    }
            } else {
                Circle()
                    .fill(isConnected ? DesignTokens.statusPhosphor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(isConnected ? "audit.kind.connected" : "audit.kind.disconnected",
                                       isConnected ? "Connected" : "Disconnected"))
    }
}
