import SwiftUI

enum SessionCardButtonPhase: Equatable {
    case disabled, idle, hovered, pressed

    static func resolve(enabled: Bool, hovered: Bool, pressed: Bool) -> Self {
        if !enabled { return .disabled }
        if pressed { return .pressed }
        return hovered ? .hovered : .idle
    }

    var fillOpacity: Double {
        switch self {
        case .disabled: 0
        case .idle: 0
        case .hovered: 0.16
        case .pressed: 0.24
        }
    }
}

/// In-card actions: visible hover feedback without resizing or moving the label.
struct SessionCardButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SessionCardButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct SessionCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: SessionCardButtonPhase {
        .resolve(enabled: enabled, hovered: hovered, pressed: configuration.isPressed)
    }

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: prominent ? .medium : .regular))
            .frame(minWidth: 14, minHeight: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? Color.white : (enabled && hovered ? DesignTokens.remoteBlue : .secondary))
            .background(DesignTokens.remoteBlue.opacity(prominent ? (phase == .pressed ? 0.7 : (phase == .hovered ? 1 : 0.9)) : phase.fillOpacity),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                DesignTokens.remoteBlue.opacity(enabled && hovered ? 0.5 : 0), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: phase)
    }
}
