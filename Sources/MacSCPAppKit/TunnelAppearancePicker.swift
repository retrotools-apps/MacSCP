import SwiftUI
import macSCPCore

extension TunnelAppearance.Icon {
    var symbol: String {
        symbol(for: .ssh)
    }
}

struct TunnelServiceIcon: View {
    let appearance: TunnelAppearance?
    var size: CGFloat = 20

    var body: some View {
        let value = appearance ?? TunnelAppearance()
        AppearanceIcon(icon: value.icon, applicationLogo: value.applicationLogo, size: size)
        .foregroundStyle(value.tint.color)
        .help(value.applicationLogo.flatMap { ApplicationLogo.record(id: $0)?.title } ?? value.icon.title)
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
                    return SessionAppearance(icon: value.icon, tint: value.tint, applicationLogo: value.applicationLogo)
                },
                set: { appearance = TunnelAppearance(icon: $0.icon, tint: $0.tint, applicationLogo: $0.applicationLogo) }), kind: .ssh)
        }
    }
}
