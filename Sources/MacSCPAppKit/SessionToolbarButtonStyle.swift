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
                .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                .frame(minWidth: prominent ? 0 : 30, minHeight: prominent ? 26 : 28)
                .padding(.horizontal, prominent ? 9 : 0)
                .foregroundStyle(prominent ? DesignTokens.remoteBlue : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(prominent
                              ? DesignTokens.remoteSoft.opacity(
                                  configuration.isPressed ? 0.7 : (isHovering ? 0.9 : 1))
                              : Color.primary.opacity(isHovering ? 0.09 : 0))
                }
                .overlay {
                    if prominent {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                DesignTokens.remoteBlue.opacity(isHovering ? 0.75 : 0.5),
                                lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
        }
    }
}
