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

enum AppearancePalette {
    static let colors: [GroupColor] = [
        0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x5AC8FA, 0x007AFF,
        0x5856D6, 0xFF2D55, 0xAF52DE, 0xA2845E, 0x636E78, 0xD6A39B
    ].map { GroupColor(rgb: $0) }
}

extension SessionAppearance {
    var displayColor: Color { customColor?.swiftUIColor ?? tint.color }
}

struct SessionAppearancePicker: View {
    @Binding var appearance: SessionAppearance
    let kind: ConnectionKind
    @State private var choosingIcon = false
    @State private var choosingColor = false

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("session.appearance.color", "Icon color")).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6), spacing: 10) {
                    ForEach(AppearancePalette.colors, id: \.self) { value in
                        Button { appearance.customColor = value } label: {
                            Circle().fill(value.swiftUIColor).frame(width: 26, height: 26)
                                .overlay {
                                    if appearance.customColor == value {
                                        Circle().fill(.white).frame(width: 9, height: 9)
                                    }
                                }
                                .overlay { Circle().strokeBorder(.primary.opacity(0.15)) }
                        }
                        .buttonStyle(.plain).help(value.hex)
                        .accessibilityLabel(value.hex)
                        .accessibilityAddTraits(appearance.customColor == value ? .isSelected : [])
                    }
                }
                Button(L10n.string("group.color.custom", "Custom color…")) { choosingColor = true }
                    .popover(isPresented: $choosingColor) {
                        ColorPicker(L10n.string("group.color.custom", "Custom color…"), selection: Binding(
                            get: { appearance.displayColor },
                            set: { if let color = GroupColor(color: $0) { appearance.customColor = color } }), supportsOpacity: false)
                            .padding(16).frame(width: 250)
                    }

            }
            Divider().frame(height: 112)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("session.appearance.icon", "Icon")).foregroundStyle(.secondary)
                Button { choosingIcon = true } label: {
                    AppearanceIcon(icon: appearance.icon, applicationLogo: appearance.applicationLogo, kind: kind, size: 30)
                        .foregroundStyle(.white).frame(width: 56, height: 56)
                        .background(appearance.displayColor, in: Circle())
                        .padding(5).overlay { Circle().stroke(appearance.displayColor, lineWidth: 2) }
                }
                .buttonStyle(.plain)
                .help(ApplicationLogo.title(for: appearance))
                .accessibilityLabel(ApplicationLogo.title(for: appearance))
                .popover(isPresented: $choosingIcon) {
                    AppearanceCataloguePicker(appearance: $appearance, kind: kind) { choosingIcon = false }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
