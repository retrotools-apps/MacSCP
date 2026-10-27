import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@MainActor
struct TablerCatalogueTests {
    @Test func fullOutlineCatalogueHasOnePickerEntryPerIconAndPreservesLegacySelections() throws {
        let indexURL = try #require(L10n.bundle.url(forResource: "TablerOutline", withExtension: "json"))
        let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        let expected = try #require(index["icons"] as? [[String: Any]]).count
        let entries = AppearanceCatalogue.entries(matching: "", source: .tabler)
        #expect(entries.count == expected)
        #expect(Set(entries.map(\.id)).count == expected)
        for record in ApplicationLogo.catalogue where record.isLegacyTabler {
            #expect(ApplicationLogo.svgData(id: record.id) != nil)
            #expect(ApplicationLogo.image(id: record.canonicalID)?.isTemplate == true)
            let saved = SessionAppearance(icon: .server, applicationLogo: record.id)
            #expect(AppearanceCatalogue.selectionID(saved) == "logo:" + record.canonicalID)
            #expect(entries.filter { $0.id == AppearanceCatalogue.selectionID(saved) }.count == 1)
        }
        #expect(!entries.contains { $0.logo?.hasPrefix("architecture-") == true })
    }

    @Test func filtersSearchTagsAndTechnicalOrderingWorkTogether() {
        let tabler = AppearanceCatalogue.entries(matching: "", source: .tabler)
        #expect(tabler.first?.family == "Computers")
        let databases = AppearanceCatalogue.entries(matching: "", source: .tabler, family: "Database")
        #expect(!databases.isEmpty)
        let unified = AppearanceCatalogue.entries(matching: "", family: "Database")
        #expect(unified.contains { $0.source == .native && $0.icon == .database })
        #expect(unified.contains { $0.source == .tabler })
        let brands = AppearanceCatalogue.entries(matching: "", family: "Brand")
        #expect(brands.contains { $0.source == .logos })
        #expect(brands.contains { $0.source == .tabler })
        #expect(databases.allSatisfy { $0.source == .tabler && $0.family == "Database" })
        #expect(AppearanceCatalogue.entries(matching: "server cog", source: .tabler).contains { $0.logo == "tabler-server-cog" })
        #expect(AppearanceCatalogue.entries(matching: "hosting", source: .tabler).contains { $0.logo == "tabler-server" })
        #expect(AppearanceCatalogue.entries(matching: "cat", source: .tabler, family: "Animals").contains { $0.logo == "tabler-cat" })
        #expect(AppearanceCatalogue.entries(matching: "", source: .logos).allSatisfy { $0.source == .logos })
        #expect(AppearanceCatalogue.entries(matching: "", source: .native).allSatisfy { $0.logo == nil })
        #expect(AppearanceCatalogue.entries(matching: " ").first?.icon == .automatic)
        #expect(AppearanceCatalogue.entries(matching: "impossible-no-such-icon").isEmpty)
    }

    @Test func categoryAndSearchLabelsExistInEveryInterfaceLanguage() throws {
        for language in ["en", "de", "fr", "es", "ro", "it", "pl"] {
            let path = try #require(L10n.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let keys = ApplicationLogo.families.map { "appearance.family." + $0.lowercased().replacingOccurrences(of: " ", with: "-") }
                + ["appearance.family.all", "appearance.resultCount %lld", "appearance.alias.network", "appearance.icon.identifier %@"]
            for key in keys { #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key) }
        }
    }

    @Test func tablerIdentifiersAndCustomColorsRoundTripForConnectionsAndTunnels() throws {
        let color = GroupColor(rgb: 0xAF73D6)
        let session = SessionAppearance(applicationLogo: "tabler-cat", customColor: color)
        let tunnel = TunnelAppearance(applicationLogo: "tabler-router", customColor: color)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(SessionAppearance.self, from: encoder.encode(session)) == session)
        #expect(try decoder.decode(TunnelAppearance.self, from: encoder.encode(tunnel)) == tunnel)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func fullCataloguePickerRendersNatively(scheme: ColorScheme) async throws {
        let view = AppearanceCataloguePicker(appearance: .constant(.init(applicationLogo: "tabler-server")), kind: .ssh, onSelect: {}, search: "server")
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 460, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let path = ProcessInfo.processInfo.environment["MACSCP_TABLER_PREVIEW"] {
            let url = URL(fileURLWithPath: path + (scheme == .dark ? ".dark.png" : ".png"))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }
}
