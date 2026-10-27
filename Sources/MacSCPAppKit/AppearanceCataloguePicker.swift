import SwiftUI
import macSCPCore

@MainActor
enum AppearanceCatalogue {
    struct Entry: Identifiable {
        let id: String
        let title: String
        let icon: SessionAppearance.Icon
        let logo: String?
    }

    static func entries(matching query: String) -> [Entry] {
        let native = SessionAppearance.Icon.allCases.filter { ApplicationLogo.resourceName(for: $0) == nil }.map {
            Entry(id: "symbol:\($0.rawValue)", title: $0.title, icon: $0, logo: nil)
        }
        let logos = ApplicationLogo.catalogue.map {
            Entry(id: "logo:\($0.id)", title: $0.displayTitle, icon: .automatic, logo: $0.id)
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (native + logos).filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || ($0.logo?.localizedStandardContains(search) ?? false)
                || ($0.logo == "esxi" && "ESXi vSphere hypervisor".localizedStandardContains(search))
                || ($0.logo == "internetbox" && "Internet box modem gateway routeur".localizedStandardContains(search))
                || ($0.logo == "ghost-mascot" && "Ghost fantôme fantome mascot".localizedStandardContains(search))
        }
    }

    static func selectionID(_ appearance: SessionAppearance) -> String {
        if let logo = appearance.applicationLogo ?? ApplicationLogo.resourceName(for: appearance.icon) { return "logo:\(logo)" }
        return "symbol:\(appearance.icon.rawValue)"
    }
}

/// Explicitly opened from the labelled Icon selector in both editors.
struct AppearanceCataloguePicker: View {
    @Binding var appearance: SessionAppearance
    let kind: ConnectionKind
    let onSelect: () -> Void
    @State var search = ""

    var body: some View {
        VStack(spacing: 12) {
            IconCatalogueSearchField(text: $search)
            let matches = AppearanceCatalogue.entries(matching: search)
            if matches.isEmpty {
                Text(L10n.string("appearance.empty", "No matching icons"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                        ForEach(matches) { entry in
                            let selected = AppearanceCatalogue.selectionID(appearance) == entry.id
                            Button {
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
                }
            }
        }
        .padding(16).frame(width: 460, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
