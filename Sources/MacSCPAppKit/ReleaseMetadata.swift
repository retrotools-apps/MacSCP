import Foundation

/// One version source for About, Settings, diagnostics and release notes.
/// Packaged metadata wins; source launches read the checkout's release file,
/// independently of the process working directory.
struct ReleaseMetadata {
    #if DEBUG
    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #else
    // Release artifacts must not embed the maintainer's absolute checkout path.
    static var sourceRoot: URL { Bundle.main.bundleURL }
    #endif
    let version: String?
    let build: String?

    init(bundle: Bundle = .main, sourceRoot: URL = Self.sourceRoot) {
        func nonempty(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let sourceVersion = try? String(contentsOf: sourceRoot.appendingPathComponent("VERSION"), encoding: .utf8)
        version = nonempty(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? nonempty(sourceVersion)
        build = nonempty(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}
