import SwiftUI

/// Compact, hosted toolbar controls with an explicit accent treatment that
/// stays readable without relying on AppKit's native prominent-button bezel.
struct SessionToolbarButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct ToolbarButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: prominent ? 12 : 13, weight: prominent ? .medium : .regular))
                .frame(minWidth: prominent ? 0 : 30, minHeight: prominent ? 22 : 28)
                .padding(.horizontal, prominent ? 6 : 0)
                .foregroundStyle(prominent ? DesignTokens.remoteBlue : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: prominent ? 4 : 6)
                        .fill(prominent
                              ? DesignTokens.remoteBlue.opacity(configuration.isPressed ? 0.2 : (isHovering ? 0.14 : 0.07))
                              : Color.primary.opacity(isHovering ? 0.09 : 0))
                }
                .overlay {
                    if prominent {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesignTokens.remoteBlue.opacity(0.3), lineWidth: 0.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: prominent ? 4 : 6))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
        }
    }
}
