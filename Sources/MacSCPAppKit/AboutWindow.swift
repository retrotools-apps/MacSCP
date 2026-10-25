import AppKit
import Foundation
import SwiftUI

/// Packaged resources take precedence; a bare SwiftPM launch reads the same
/// release files from the source checkout, never from the working directory.
struct AboutContent {
    static let copyrightPrefix = "© 2026"
    static let brand = "RetroTools"
    static let brandFontName = "Monaco"
    static let signatureFontName = "Zapfino"
    static let signature = "by Karel"
    static let copyright = copyrightPrefix + " " + brand
    let version: String?
    let licenseURL: URL?
    let noticesURL: URL?

    init(bundle: Bundle = .main, sourceRoot: URL = ReleaseMetadata.sourceRoot) {
        version = ReleaseMetadata(bundle: bundle, sourceRoot: sourceRoot).version
        func resource(_ name: String, extension ext: String?, sourceSubdirectory: String? = nil) -> URL? {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
            let root = sourceSubdirectory.map { sourceRoot.appendingPathComponent($0) } ?? sourceRoot
            let url = root.appendingPathComponent(ext.map { name + "." + $0 } ?? name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        licenseURL = resource("LICENSE", extension: nil)
        noticesURL = resource("THIRD_PARTY_NOTICES", extension: "pdf", sourceSubdirectory: "output/pdf")
    }

}

@MainActor
enum AboutWindow {
    private static var controller: NSWindowController?

    static func show() {
        if controller == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.string("about.title", "About MacSCP")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutView())
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    let content = AboutContent()

    var body: some View {
        VStack(spacing: 0) {
            if let icon = ApplicationIcon.load() {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
            }
            L10n.text("about.appName", "MacSCP")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .padding(.top, 14)
            L10n.text("about.subtitle", "Secure file transfers for macOS")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text(versionLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(.top, 14)
            Text(verbatim: AboutContent.signature)
                .font(.custom(AboutContent.signatureFontName, size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
                .padding(.bottom, 3)
            HStack(spacing: 6) {
                Text(AboutContent.copyrightPrefix)
                    .font(.system(size: 12, weight: .medium))
                Text(AboutContent.brand)
                    .font(.custom(AboutContent.brandFontName, size: 13))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AboutContent.copyright)
            HStack(spacing: 20) {
                documentButton("about.license", "MacSCP License", url: content.licenseURL)
                documentButton("about.thirdParty", "Third-party licenses", url: content.noticesURL)
            }
            .font(.system(size: 11))
            .padding(.top, 12)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(width: 420, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var versionLabel: String {
        guard let version = content.version else {
            return L10n.string("settings.general.currentVersion.unknown", "Unknown")
        }
        return String(format: L10n.string("about.version %@", "Version %@"), version)
    }

    private func documentButton(_ key: String, _ fallback: String, url: URL?) -> some View {
        Button(L10n.string(key, fallback)) {
            if let url { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
        .disabled(url == nil)
    }
}
