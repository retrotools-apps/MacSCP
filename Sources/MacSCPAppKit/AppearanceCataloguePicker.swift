import SwiftUI
import macSCPCore

@MainActor
enum AppearanceCatalogue {
    /// Provider metadata stays internal to ordering, attribution and validation.
    enum Source: String { case native, tabler, logos }
    struct Entry: Identifiable {
        let id: String
        let title: String
        let icon: SessionAppearance.Icon
        let logo: String?
        let source: Source
        let family: String?
        let searchKey: String
    }

    private static let technicalFamilies = ["Computers", "Devices", "Database", "Development", "Version control", "System", "Communication"]
    static var families: [String] {
        _ = allEntries()
        let titles = cachedFamilyTitles
        return ApplicationLogo.families.sorted {
            let a = technicalFamilies.firstIndex(of: $0) ?? technicalFamilies.count
            let b = technicalFamilies.firstIndex(of: $1) ?? technicalFamilies.count
            return a == b ? (titles[$0] ?? $0).localizedStandardCompare(titles[$1] ?? $1) == .orderedAscending : a < b
        }
    }
    static func familyTitle(_ name: String) -> String {
        _ = allEntries()
        return cachedFamilyTitles[name] ?? name
    }

    /// Build normalized search text once per interface language, not on each
    /// keystroke or cell hover. SVG decoding remains lazy in ApplicationLogo.
    private static var cachedLanguage = ""
    private static var cachedEntries: [Entry] = []
    private static var cachedFamilyTitles: [String: String] = [:]
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
    private static func allEntries() -> [Entry] {
        let language = LocalizationContext.shared.localizedBundle(in: L10n.bundle).bundlePath
        if cachedLanguage == language { return cachedEntries }
        let familyTitles = Dictionary(uniqueKeysWithValues: ApplicationLogo.families.map { name in
            let key = "appearance.family." + name.lowercased().replacingOccurrences(of: " ", with: "-")
            return (name, L10n.string(key, name))
        })
        let aliases: [(Set<String>, String)] = [
            (["server", "hosting", "datacenter"], L10n.string("appearance.alias.server", "server host hosting")),
            (["network", "router", "wifi", "ethernet", "topology", "route"], L10n.string("appearance.alias.network", "network router connection")),
            (["database", "sql", "mysql", "postgresql"], L10n.string("appearance.alias.database", "database data storage")),
            (["cloud"], L10n.string("appearance.alias.cloud", "cloud hosting")),
            (["lock", "shield", "password", "key", "firewall", "security"], L10n.string("appearance.alias.security", "security lock password key firewall")),
            (["file", "folder", "document"], L10n.string("appearance.alias.files", "file folder document")),
            (["computer", "device", "laptop", "desktop", "cpu"], L10n.string("appearance.alias.devices", "computer device laptop processor")),
        ]
        let native = SessionAppearance.Icon.allCases.filter { ApplicationLogo.resourceName(for: $0) == nil }.map {
            let family = nativeFamily($0)
            let title = $0.title
            return Entry(id: "symbol:\($0.rawValue)", title: title, icon: $0, logo: nil,
                  source: .native, family: family,
                  searchKey: normalized(title + " " + $0.rawValue + " " + (family.flatMap { familyTitles[$0] } ?? "")))
        }
        let identifierTitle = L10n.string("appearance.icon.identifier %@", "Icon · %@")
        let artwork = ApplicationLogo.catalogue.filter { !$0.isLegacyTabler }.map { record in
            let source: Source = record.origin == "tabler-icons" ? .tabler : .logos
            let title = record.sourceName.map { String(format: identifierTitle, $0) } ?? record.displayTitle
            let family = record.category ?? "Brand"
            var keywords = [title, record.id, family, record.tags?.joined(separator: " ") ?? ""]
            keywords.append(familyTitles[family] ?? family)
            let words = Set(normalized(keywords.joined(separator: " ")).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            for (concept, text) in aliases where !concept.isDisjoint(with: words) { keywords.append(text) }
            switch record.id {
            case "esxi": keywords.append("ESXi vSphere hypervisor")
            case "internetbox": keywords.append("Internet box modem gateway routeur")
            case "ghost-mascot": keywords.append("Ghost fantôme fantome mascot")
            default: break
            }
            return Entry(id: "logo:\(record.id)", title: title, icon: .automatic, logo: record.id,
                         source: source, family: family, searchKey: normalized(keywords.joined(separator: " ")))
        }
        func rank(_ entry: Entry) -> Int {
            if entry.source == .native { return 0 }
            if let family = entry.family, technicalFamilies.contains(family) { return 1 }
            return entry.source == .logos ? 2 : 3
        }
        let nativeOrder = Dictionary(uniqueKeysWithValues: native.enumerated().map { ($0.element.id, $0.offset) })
        cachedEntries = (native + artwork).sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            if a == 0 { return (nativeOrder[$0.id] ?? 0) < (nativeOrder[$1.id] ?? 0) }
            if $0.family != $1.family {
                let x = technicalFamilies.firstIndex(of: $0.family ?? "") ?? technicalFamilies.count
                let y = technicalFamilies.firstIndex(of: $1.family ?? "") ?? technicalFamilies.count
                if x != y { return x < y }
                if x == technicalFamilies.count { return ($0.family ?? "") < ($1.family ?? "") }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        cachedFamilyTitles = familyTitles
        cachedLanguage = language
        return cachedEntries
    }

    static func entries(matching query: String, source: Source? = nil, family: String? = nil) -> [Entry] {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return allEntries().filter { entry in
            (source == nil || entry.source == source) && (family == nil || entry.family == family)
                && tokens.allSatisfy { entry.searchKey.contains($0) }
        }
    }

    private static func nativeFamily(_ icon: SessionAppearance.Icon) -> String? {
        switch icon {
        case .automatic: nil
        case .server, .storage, .backup, .device, .mobile: "Devices"
        case .desktop, .laptop, .ai, .robot, .remoteDesktop: "Computers"
        case .database: "Database"
        case .router, .networkSwitch, .cloud, .web, .secureWeb, .dns, .mail, .messaging: "Communication"
        case .api, .container, .ssh, .logs, .analyzer: "Development"
        case .files, .directory: "Document"
        case .media: "Media"
        default: "System"
        }
    }

    static func selectionID(_ appearance: SessionAppearance) -> String {
        if let logo = appearance.applicationLogo ?? ApplicationLogo.resourceName(for: appearance.icon) {
            return "logo:\(ApplicationLogo.record(id: logo)?.canonicalID ?? logo)"
        }
        return "symbol:\(appearance.icon.rawValue)"
    }
}

/// Explicitly opened from the labelled Icon selector in both editors.
struct AppearanceCataloguePicker: View {
    @Binding var appearance: SessionAppearance
    let kind: ConnectionKind
    let onSelect: () -> Void
    @State var search = ""
    @State private var family: String?

    var body: some View {
        let matches = AppearanceCatalogue.entries(matching: search, family: family)
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                IconCatalogueSearchField(text: $search)
                familyFilter
            }
            if matches.isEmpty {
                Text(L10n.string("appearance.empty", "No matching icons"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                        ForEach(matches) { entry in
                            catalogueCell(entry)
                        }
                    }
                }
                .id((family ?? "") + ":" + search)
            }
            Text(String(format: L10n.string("appearance.resultCount %lld", "Icons: %lld"), Int64(matches.count)))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16).frame(width: 460, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var familyFilter: some View {
        Picker(L10n.string("appearance.family", "Family"), selection: $family) {
            Text(L10n.string("appearance.family.all", "All families")).tag(nil as String?)
            ForEach(AppearanceCatalogue.families, id: \.self) { item in
                Text(AppearanceCatalogue.familyTitle(item)).tag(Optional(item))
            }
        }
        .labelsHidden().frame(width: 170).pickerStyle(.menu)
    }

    private func catalogueCell(_ entry: AppearanceCatalogue.Entry) -> some View {
        let selected = AppearanceCatalogue.selectionID(appearance) == entry.id
        return Button {
            appearance.icon = entry.icon
            appearance.applicationLogo = entry.logo
            onSelect()
        } label: {
            AppearanceIcon(icon: entry.icon, applicationLogo: entry.logo, kind: kind, size: 24)
                .foregroundStyle(selected ? .white : Color.primary.opacity(0.7))
                .frame(width: 42, height: 42)
                .background(selected ? appearance.displayColor : Color.primary.opacity(0.08), in: Circle())
                .padding(4)
                .overlay { Circle().stroke(selected ? appearance.displayColor : .clear, lineWidth: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(entry.title).accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
