import AppKit
import SwiftUI

/// Original SVG artwork exported as vector PDFs, not font-catalog symbols.
struct SidebarGroupActionIcon: View {
    enum Action: String, CaseIterable {
        case expand, collapse
    }

    @Environment(\.colorScheme) private var colorScheme
    let action: Action

    @MainActor
    static func image(action: Action, style: String) -> NSImage? {
        artwork["group-\(action.rawValue)-\(style)"]
    }

    @MainActor private static let artwork: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for action in Action.allCases {
            for style in ["black", "white", "color", "color-dark"] {
                let name = "group-\(action.rawValue)-\(style)"
                if let url = L10n.bundle.url(forResource: name, withExtension: "pdf"),
                   let image = NSImage(contentsOf: url) { images[name] = image }
            }
        }
        return images
    }()

    var body: some View {
        if let image = Self.image(action: action, style: colorScheme == .dark ? "color-dark" : "color") {
            Image(nsImage: image).renderingMode(.original)
                .resizable().scaledToFit().frame(width: 19, height: 19)
                .accessibilityHidden(true)
        }
    }
}
