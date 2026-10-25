import SwiftUI
import macSCPCore

extension SessionAppearance.Icon {
    var title: String { L10n.string("session.icon.\(rawValue)", rawValue) }

    func symbol(for kind: ConnectionKind) -> String {
        switch self {
        case .automatic: kind == .ssh ? "server.rack" : "cloud"
        case .server: "server.rack"
        case .database: "cylinder.split.1x2"
        case .bastion: "lock.shield"
        case .firewall: "flame"
        case .router: "wifi.router"
        case .internetBox: "wifi.router"
        case .ghost: "person.crop.square"
        case .networkSwitch: "point.3.connected.trianglepath.dotted"
        case .ai: "brain"
        case .web: "globe"
        case .storage: "externaldrive"
        case .cloud: "cloud"
        case .desktop: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .backup: "archivebox"
        case .mail: "envelope"
        case .container: "shippingbox"
        case .api: "curlybraces"
        case .dns: "network"
        case .media: "play.rectangle"
        case .device: "cpu"
        case .honeypot: "ladybug"
        case .analyzer: "waveform.path.ecg"
        case .mobile: "iphone"
        case .robot: "gearshape.2"
        case .secureWeb: "lock.rectangle"
        case .remoteDesktop: "desktopcomputer"
        case .ssh: "terminal"
        case .files: "folder"
        case .monitoring: "chart.xyaxis.line"
        case .logs: "text.alignleft"
        case .directory: "person.2"
        case .messaging: "bubble.left.and.bubble.right"
        case .vmwareESXi: "square.stack.3d.up"
        case .kibana: "chart.bar.xaxis"
        case .redis: "square.3.layers.3d"
        case .mysql, .postgresql, .mongodb: "cylinder.split.1x2"
        case .apache, .nginx: "globe"
        case .php: "chevron.left.forwardslash.chevron.right"
        case .tomcat: "cup.and.saucer"
        case .elasticsearch: "magnifyingglass"
        case .grafana: "gauge.with.dots.needle.50percent"
        case .prometheus: "flame"
        case .docker: "shippingbox"
        case .kubernetes: "helm"
        case .gitlab: "point.3.connected.trianglepath.dotted"
        case .jenkins: "hammer"
        }
    }
}

extension SessionAppearance.Tint {
    var title: String { L10n.string("session.tint.\(rawValue)", rawValue) }

    var color: Color {
        switch self {
        case .blue: DesignTokens.remoteBlue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

struct SessionAppearancePicker: View {
    @Binding var appearance: SessionAppearance
    let kind: ConnectionKind
    @State private var choosingIcon = false

    var body: some View {
        FormRow(label: L10n.string("session.appearance.icon", "Icon")) {
            HStack(spacing: 12) {
                AppearanceIcon(icon: appearance.icon, applicationLogo: appearance.applicationLogo, kind: kind)
                    .foregroundStyle(appearance.tint.color)
                    .frame(width: 32, height: 32)
                    .help(ApplicationLogo.title(for: appearance))
                    .accessibilityHidden(true)
                Button { choosingIcon = true } label: {
                    HStack {
                        Text(ApplicationLogo.title(for: appearance)).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                }
                .help(L10n.string("session.appearance.icon", "Icon"))
                .frame(width: 240)
                .popover(isPresented: $choosingIcon) {
                    AppearanceCataloguePicker(appearance: $appearance, kind: kind) { choosingIcon = false }
                }
                Spacer(minLength: 0)
            }
        }
        FormRow(label: L10n.string("session.appearance.color", "Icon color")) {
            AppearanceTintPicker(tint: $appearance.tint)
        }
    }
}

/// Shared palette for device-oriented sessions and service-oriented tunnels.
struct AppearanceTintPicker: View {
    @Binding var tint: SessionAppearance.Tint

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SessionAppearance.Tint.allCases, id: \.self) { option in
                Button { tint = option } label: {
                    Circle().fill(option.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            if tint == option {
                                Circle().strokeBorder(.primary, lineWidth: 1.5).padding(-3)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(tint == option ? .isSelected : [])
            }
        }
    }
}
