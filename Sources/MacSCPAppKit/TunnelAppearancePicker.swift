import SwiftUI
import macSCPCore

extension TunnelAppearance.Icon {
    var symbol: String {
        symbol(for: .ssh)
    }
}

struct TunnelServiceIcon: View {
    @Environment(\.groupForeground) private var groupForeground
    let appearance: TunnelAppearance?
    var size: CGFloat = 20

    var body: some View {
        let value = appearance ?? TunnelAppearance()
        AppearanceIcon(icon: value.icon, applicationLogo: value.applicationLogo, size: size)
        .foregroundStyle(groupForeground == nil ? (value.customColor?.swiftUIColor ?? value.tint.color) : .white)
        .background {
            if groupForeground != nil { Circle().fill(value.customColor?.swiftUIColor ?? value.tint.color).padding(-3) }
        }
        .help(value.applicationLogo.flatMap { ApplicationLogo.record(id: $0)?.displayTitle } ?? value.icon.title)
        .accessibilityHidden(true)
    }
}

/// The connection editor's visible, labelled fields and shared catalogue.
struct TunnelAppearancePicker: View {
    @Binding var appearance: TunnelAppearance?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SessionAppearancePicker(appearance: Binding(
                get: {
                    let value = appearance ?? TunnelAppearance()
                    return SessionAppearance(icon: value.icon, tint: value.tint, applicationLogo: value.applicationLogo, customColor: value.customColor)
                },
                set: { appearance = TunnelAppearance(icon: $0.icon, tint: $0.tint, applicationLogo: $0.applicationLogo, customColor: $0.customColor) }), kind: .ssh)
        }
    }
}
