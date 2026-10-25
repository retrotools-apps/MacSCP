import SwiftUI
import macSCPCore

private struct GroupColorsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    @Entry var usedGroupColors: Set<GroupColor> = []
    var groupColorsEnabled: Bool {
        get { self[GroupColorsEnabledKey.self] }
        set { self[GroupColorsEnabledKey.self] = newValue }
    }
}

/// Joined row backgrounds preserve List's flat, stable row identities while
/// drawing one rounded region around a group and all its visible descendants.
enum SidebarGroupBands {
    struct Group {
        let id: UUID
        let parentID: UUID?
        let name: String
        let colorHue: Double?
        let color: GroupColor?
        init(_ group: StoredGroup) { id = group.id; parentID = group.parentID; name = group.name; colorHue = group.colorHue; color = group.color }
        init(_ group: TunnelGroup) { id = group.id; parentID = group.parentID; name = group.name; colorHue = group.colorHue; color = group.color }
    }
    struct Entry {
        let id: UUID
        let groupID: UUID?
    }
    struct Layer: Equatable {
        let groupID: UUID
        let depth: Int
        let hue: Double
        let color: GroupColor?
        let darkerNeutral: Bool
        let starts: Bool
        let ends: Bool
        let startFraction: Double
        let endFraction: Double
    }

    /// Alternate siblings and nesting levels independently of saved hue choices.
    static func neutralVariants(groups: [Group]) -> [UUID: Bool] {
        let known = Set(groups.map(\.id))
        var result: [UUID: Bool] = [:]
        func assign(_ siblings: [Group], depth: Int) {
            for (index, group) in DisplayNameOrder.sorted(siblings, by: \.name).enumerated() {
                guard result[group.id] == nil else { continue }
                result[group.id] = (index + depth).isMultiple(of: 2) == false
                assign(groups.filter { $0.parentID == group.id }, depth: depth + 1)
            }
        }
        assign(groups.filter { $0.parentID.map { !known.contains($0) } ?? true }, depth: 0)
        return result
    }

    /// Use the complete hierarchy, not visible rows, so filtering and folding
    /// cannot change an item's color. Adjacent siblings use separated hues.
    static func hues(groups: [Group]) -> [UUID: Double] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: Double] = [:]
        func assign(_ siblings: [Group], parentHue: Double?) {
            for (index, group) in DisplayNameOrder.sorted(siblings, by: \.name).enumerated() {
                guard result[group.id] == nil else { continue }
                let automaticHue = ((parentHue.map { $0 + 0.19 } ?? 0.62) + Double(index) * 0.61803398875)
                    .truncatingRemainder(dividingBy: 1)
                let hue = group.color?.hue
                    ?? group.colorHue.flatMap { (0..<1).contains($0) ? $0 : nil } ?? automaticHue
                result[group.id] = hue
                assign(groups.filter { $0.parentID == group.id }, parentHue: hue)
            }
        }
        assign(groups.filter { $0.parentID.flatMap { byID[$0] } == nil }, parentHue: nil)
        return result
    }

    static func build(entries: [Entry], groups: [Group]) -> [UUID: [Layer]] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hues = hues(groups: groups)
        let neutralVariants = neutralVariants(groups: groups)
        func path(_ id: UUID?) -> [UUID] {
            var result: [UUID] = [], seen: Set<UUID> = []
            var current = id
            while let id = current, let group = byID[id], seen.insert(id).inserted {
                result.append(id); current = group.parentID
            }
            return result.reversed()
        }
        let paths = entries.map { path($0.groupID) }
        var intervals: [UUID: ClosedRange<Int>] = [:]
        for (index, path) in paths.enumerated() {
            for id in path { intervals[id] = (intervals[id]?.lowerBound ?? index)...index }
        }
        return Dictionary(entries.enumerated().map { index, entry in
            let path = paths[index]
            let layers = path.enumerated().compactMap { depth, id -> Layer? in
                guard let interval = intervals[id] else { return nil }
                let count = Double(interval.count)
                return Layer(groupID: id, depth: depth,
                    hue: hues[id] ?? 0.62,
                    color: byID[id]?.color,
                    darkerNeutral: neutralVariants[id] ?? false,
                    starts: index == interval.lowerBound, ends: index == interval.upperBound,
                    startFraction: Double(index - interval.lowerBound) / count,
                    endFraction: Double(index - interval.lowerBound + 1) / count)
            }
            return (entry.id, layers)
        }, uniquingKeysWith: { first, _ in first })
    }

    static func connections(_ rows: [SidebarVisibleRows.Row], visibility: SidebarVisibility,
                            groups: [StoredGroup]) -> [UUID: [Layer]] {
        build(entries: rows.map { row in
            let groupID: UUID?
            switch row.item {
            case .group(let id): groupID = id
            case .session(let id): groupID = visibility.session(id)?.groupID
            }
            return Entry(id: row.id, groupID: groupID)
        }, groups: groups.map(Group.init))
    }

    static func tunnels(_ rows: [TunnelCatalog.SidebarRow], groups: [TunnelGroup]) -> [UUID: [Layer]] {
        build(entries: rows.map { row in
            switch row {
            case .group(let row): Entry(id: row.id, groupID: row.id)
            case .profile(let profile, _): Entry(id: profile.id, groupID: profile.groupID)
            }
        }, groups: groups.map(Group.init))
    }
}

struct SidebarGroupBandBackground: View {
    let layers: [SidebarGroupBands.Layer]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.groupColorsEnabled) private var colorsEnabled
    var body: some View {
        ZStack {
            ForEach(layers, id: \.groupID) { layer in
                let base = colorsEnabled ? (layer.depth == 0 ? 0.045 : 0.085)
                    : GroupNeutralStyle.opacity(darker: layer.darkerNeutral, dark: scheme == .dark)
                let color = colorsEnabled
                    ? (layer.color?.swiftUIColor ?? Color(hue: layer.hue, saturation: scheme == .dark ? 0.38 : 0.45,
                            brightness: scheme == .dark ? 0.94 : 0.82))
                    : Color.primary
                UnevenRoundedRectangle(topLeadingRadius: layer.starts ? 8 : 0,
                    bottomLeadingRadius: layer.ends ? 8 : 0,
                    bottomTrailingRadius: layer.ends ? 8 : 0,
                    topTrailingRadius: layer.starts ? 8 : 0)
                    .fill(LinearGradient(colors: [color.opacity(base + layer.startFraction * 0.02),
                                                  color.opacity(base + layer.endFraction * 0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(.leading, 4 + SidebarIndentation.leading(depth: layer.depth))
                    .padding(.trailing, 4 + SidebarIndentation.leading(depth: layer.depth))
                    .padding(.top, layer.starts ? (layer.depth == 0 ? 8 : 2) : 0)
                    .padding(.bottom, layer.ends && layer.depth > 0 ? 2 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shared by connection cards and tunnel rows; group tint never replaces status.
struct GroupContentTint: View {
    let hue: Double?
    var darkerNeutral = false
    var customColor: GroupColor? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.groupColorsEnabled) private var colorsEnabled
    var body: some View {
        if hue != nil || customColor != nil {
            let color = colorsEnabled
                ? (customColor?.swiftUIColor ?? Color(hue: hue ?? 0.62, saturation: scheme == .dark ? 0.38 : 0.45,
                        brightness: scheme == .dark ? 0.94 : 0.82))
                : Color.primary
            color.opacity(colorsEnabled ? GroupTintStyle.cardOpacity(dark: scheme == .dark)
                : GroupTintStyle.cardNeutralOpacity(
                    darker: darkerNeutral, dark: scheme == .dark))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

enum GroupTintStyle {
    /// Full-card tint must remain a cue, not a second surface colour. These
    /// values keep semantic primary/secondary text readable in both schemes.
    static func cardOpacity(dark: Bool) -> Double { dark ? 0.055 : 0.045 }
    /// Light cards keep their white surface when group colours are disabled;
    /// the alternating neutral treatment is useful only against dark chrome.
    static func cardNeutralOpacity(darker: Bool, dark: Bool) -> Double {
        dark ? (darker ? 0.09 : 0.045) : 0
    }
    static func tunnelAccentOpacity(dark: Bool) -> Double { dark ? 0.82 : 0.72 }
    static func tunnelRowOpacity(alternate: Bool, dark: Bool) -> Double {
        dark ? (alternate ? 0.035 : 0.018) : 0
    }
}

/// Tunnel rows stay neutral for legibility. Group colour is retained only as
/// a narrow leading accent, so selection and status colours remain dominant.
struct TunnelGroupAccent: View {
    let hue: Double?
    var customColor: GroupColor? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.groupColorsEnabled) private var colorsEnabled
    var body: some View {
        if hue != nil || customColor != nil {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colorsEnabled
                    ? (customColor?.swiftUIColor ?? Color(hue: hue ?? 0.62, saturation: 0.52, brightness: 0.88))
                        .opacity(GroupTintStyle.tunnelAccentOpacity(dark: scheme == .dark))
                    : Color.secondary.opacity(0.28))
                .frame(width: 3)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

enum GroupNeutralStyle {
    static func opacity(darker: Bool, dark: Bool) -> Double {
        dark ? (darker ? 0.09 : 0.045) : (darker ? 0.065 : 0.035)
    }
}

/// An sRGB identifier is rendered behind semantic text at bounded opacity.
extension GroupColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    @MainActor init?(color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        self.init(rgb: (byte(rgb.redComponent) << 16) | (byte(rgb.greenComponent) << 8) | byte(rgb.blueComponent))
    }
}

/// One compact, directly accessible picker for both kinds of groups.
struct GroupColorControl: View {
    let hue: Double?
    var color: GroupColor? = nil
    @Binding var isPresented: Bool
    let onChange: (GroupColor?) -> Void
    @Environment(\.groupColorsEnabled) private var colorsEnabled
    var body: some View {
        Button { isPresented.toggle() } label: {
            Circle().fill(colorsEnabled
                ? (color?.swiftUIColor ?? hue.map { Color(hue: $0, saturation: 0.5, brightness: 0.85) } ?? Color.secondary.opacity(0.3))
                : Color.secondary.opacity(0.3))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
                .frame(width: 12, height: 12).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!colorsEnabled)
        .help(L10n.string("group.color", "Group color"))
        .accessibilityLabel(L10n.string("group.color", "Group color"))
        .popover(isPresented: $isPresented) { GroupColorPicker(hue: hue, color: color, onChange: onChange) }
    }
}

struct GroupColorPicker: View {
    let hue: Double?
    let color: GroupColor?
    let onChange: (GroupColor?) -> Void
    @Environment(\.usedGroupColors) private var usedColors
    @AppStorage("groupColorSwatches") private var storedSwatches = ""
    @State private var choosingCustom = false
    @State private var customColor: Color
    @State private var selected: GroupColor?

    static let swatches = GroupColorPalette.defaults

    private var palette: [GroupColor] {
        let stored = storedSwatches.split(separator: ",").compactMap { GroupColor(hex: String($0)) }
        var seen: Set<GroupColor> = []
        var values = (stored.isEmpty ? Self.swatches : stored).filter { seen.insert($0).inserted }
        if let selected, !values.contains(selected) { values.append(selected) }
        return values
    }

    init(hue: Double?, color: GroupColor? = nil, onChange: @escaping (GroupColor?) -> Void) {
        self.hue = hue; self.color = color; self.onChange = onChange
        _selected = State(initialValue: color)
        _customColor = State(initialValue: color?.swiftUIColor ?? Color(hue: hue ?? 0.3, saturation: 0.4, brightness: 0.8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("group.color", "Group color")).font(.headline)
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 8), spacing: 6) {
                    ForEach(palette, id: \.self) { value in swatch(value) }
                }
            }
            .frame(height: min(160, CGFloat((palette.count + 7) / 8) * 28 - 6))
            Button {
                customColor = selected?.swiftUIColor ?? customColor
                choosingCustom = true
            } label: {
                Label(L10n.string("group.color.custom", "Custom color…"), systemImage: "paintpalette")
            }
            .help(L10n.string("group.color.custom", "Custom color…"))
            .frame(maxWidth: .infinity)
            Divider()
            Button(L10n.string("session.icon.automatic", "Automatic")) {
                selected = nil
                onChange(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14).frame(width: 252)
        .sheet(isPresented: $choosingCustom) {
            VStack(alignment: .leading, spacing: 16) {
                ColorPicker(L10n.string("group.color", "Group color"), selection: $customColor, supportsOpacity: false)
                HStack {
                    Button(L10n.string("common.cancel", "Cancel")) { choosingCustom = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.string("group.color.use", "Use color")) {
                        guard let value = GroupColor(color: customColor) else { return }
                        let values = GroupColorPalette.adding(value, to: palette, used: usedColors)
                        storedSwatches = values.map(\.hex).joined(separator: ",")
                        selected = value
                        onChange(value)
                        choosingCustom = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 300)
        }
    }

    private func swatch(_ value: GroupColor) -> some View {
        Button { selected = value; onChange(value) } label: {
            Circle().fill(value.swiftUIColor)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(selected == value ? 0.9 : 0.2),
                                          lineWidth: selected == value ? 2 : 1)
                }
                .overlay {
                    if selected == value {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(value.relativeLuminance > 0.179 ? .black : .white)
                            .accessibilityHidden(true)
                            .help(value.hex)
                    }
                }
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(value.hex)
        .accessibilityLabel(value.hex)
        .accessibilityAddTraits(selected == value ? .isSelected : [])
    }
}
