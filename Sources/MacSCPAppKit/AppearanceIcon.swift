import AppKit
import Compression
import SwiftUI
import macSCPCore

/// Bundled SVG originals from reviewed providers; no network lookup at runtime.
@MainActor
enum ApplicationLogo {
    struct Record: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
        let offset: Int
        let compressedSize: Int
        let originalSize: Int
        let sha256: String
        let origin: String?
        let sourceName: String?
        let category: String?
        let tags: [String]?

        var isLegacyTabler: Bool { origin == "tabler-icons" && id.hasPrefix("architecture-") }
        var canonicalID: String {
            isLegacyTabler ? "tabler-" + id.dropFirst("architecture-".count) : id
        }

        @MainActor var displayTitle: String {
            if let sourceName {
                return String(format: L10n.string("appearance.icon.identifier %@", "Icon · %@"), sourceName)
            }
            return switch id {
            case "internetbox": SessionAppearance.Icon.internetBox.title
            case "ghost-mascot": SessionAppearance.Icon.ghost.title
            case "esxi": SessionAppearance.Icon.vmwareESXi.title
            default: title
            }
        }
    }

    private struct Index: Decodable {
        let icons: [Record]
        let categories: [String]?
    }
    private static func index(_ name: String) -> Index? {
        guard let url = L10n.bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }
    private static let outline = index("TablerOutline")
    static let families: [String] = outline?.categories ?? []
    static let catalogue: [Record] = (index("ApplicationLogos")?.icons ?? []) + (outline?.icons ?? [])
    private static let byID = Dictionary(uniqueKeysWithValues: catalogue.map { ($0.id, $0) })
    private static let archive: Data = {
        guard let url = L10n.bundle.url(forResource: "ApplicationLogos", withExtension: "bin") else { return Data() }
        return (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
    }()
    private static let outlineArchive: Data = {
        guard let url = L10n.bundle.url(forResource: "TablerOutline", withExtension: "bin") else { return Data() }
        return (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
    }()
    private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>()
        value.countLimit = 128
        return value
    }()

    static func record(id: String) -> Record? { byID[id] }

    static func resourceName(for icon: SessionAppearance.Icon) -> String? {
        switch icon {
        case .vmwareESXi: "esxi"
        case .internetBox: "internetbox"
        case .ghost: "ghost-mascot"
        case .tomcat: "apachetomcat"
        case .kibana, .redis, .mysql, .apache, .php, .nginx, .postgresql, .mongodb,
             .elasticsearch, .grafana, .prometheus, .docker, .kubernetes, .gitlab, .jenkins:
            icon.rawValue
        default: nil
        }
    }

    static func svgData(id: String) -> Data? {
        guard let record = byID[id] else { return nil }
        let payload = record.sourceName == nil ? archive : outlineArchive
        guard record.offset >= 0, record.compressedSize > 0,
              record.originalSize > 0, record.originalSize <= 512 * 1024,
              record.offset <= payload.count, record.compressedSize <= payload.count - record.offset else { return nil }
        let source = payload.subdata(in: record.offset..<(record.offset + record.compressedSize))
        var output = [UInt8](repeating: 0, count: record.originalSize)
        let count = source.withUnsafeBytes { packed in
            output.withUnsafeMutableBufferPointer { unpacked in
                compression_decode_buffer(unpacked.baseAddress!, unpacked.count,
                    packed.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        return count == record.originalSize ? Data(output) : nil
    }

    static func image(id: String) -> NSImage? {
        if let value = cache.object(forKey: id as NSString) { return value }
        guard let data = svgData(id: id), let image = NSImage(data: data), image.isValid else { return nil }
        image.isTemplate = true
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    static func image(for icon: SessionAppearance.Icon) -> NSImage? {
        resourceName(for: icon).flatMap { image(id: $0) }
    }

    static func title(for appearance: SessionAppearance) -> String {
        if let id = appearance.applicationLogo, let record = byID[id] { return record.displayTitle }
        return appearance.icon.title
    }
}

/// One renderer for both catalogues, previews, cards and tunnel rows.
struct AppearanceIcon: View {
    let icon: SessionAppearance.Icon
    var applicationLogo: String? = nil
    var kind: ConnectionKind = .ssh
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let logo = applicationLogo.flatMap({ ApplicationLogo.image(id: $0) }) ?? ApplicationLogo.image(for: icon) {
                Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: icon.symbol(for: kind)).font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .help(applicationLogo.flatMap { ApplicationLogo.record(id: $0)?.displayTitle } ?? icon.title)
        .accessibilityHidden(true)
    }
}
