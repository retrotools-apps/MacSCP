import SwiftUI

struct SidebarWorkspaceHeading: View {
    let title: String
    var body: some View {
        Text(title).textCase(.uppercase)
            .font(.system(size: 10.5, weight: .semibold)).tracking(1.0)
            .foregroundStyle(DesignTokens.inkTertiary)
            .padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// One native list surface and one density for all navigation workspaces.
struct SidebarList<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        List {
            content()
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 24)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
    }
}

struct SidebarNavigationLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 6) {
            Group {
                // The tunnel mark is a bundled vector, not an SF Symbol
                // available on every supported macOS version.
                if symbol == "apple.health.trends" {
                    TunnelIcon(size: 14)
                } else {
                    Image(systemName: symbol).font(.system(size: 14)).help(title)
                }
            }
            .frame(width: 18).foregroundStyle(Color.accentColor)
            .accessibilityHidden(true).help(title)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
