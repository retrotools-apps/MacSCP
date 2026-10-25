import SwiftUI

enum SidebarIndentation {
    static func leading(depth: Int) -> CGFloat { CGFloat(max(0, depth)) * 8 }
}

/// A disclosure button independent of List's implicit outline columns. The
/// label keeps its own drag/drop, rename field, and context menu.
struct SidebarGroupHeader<Label: View>: View {
    @Binding var isExpanded: Bool
    let name: String
    var isSelected = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(name)
            .accessibilityLabel(name)
            .accessibilityValue(isExpanded
                ? L10n.string("sidebar.group.expanded", "Expanded")
                : L10n.string("sidebar.group.collapsed", "Collapsed"))
            label()
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(
            isSelected ? DesignTokens.remoteBlue.opacity(0.12) : .clear))
    }
}
