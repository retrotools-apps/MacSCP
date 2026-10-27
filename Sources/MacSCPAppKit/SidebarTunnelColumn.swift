import SwiftUI

/// Reserve the same trailing space on every normal connection row, including
/// rows without tunnels. Counts may shrink within it without moving the badge.
struct SidebarTunnelColumn<Content: View>: View {
    static var width: CGFloat { 28 }
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear.accessibilityHidden(true)
            content()
        }
        .frame(width: Self.width, height: 14)
    }
}
