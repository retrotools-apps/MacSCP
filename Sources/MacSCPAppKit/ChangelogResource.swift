import Foundation

/// Prefer the packaged changelog; source launches use the canonical release
/// document from the checkout rather than depending on the working directory.
enum ChangelogResource {
    static func load(bundle: Bundle = .main, sourceRoot: URL = ReleaseMetadata.sourceRoot) -> String? {
        let url = bundle.url(forResource: "CHANGELOG", withExtension: "md")
            ?? sourceRoot.appendingPathComponent("CHANGELOG.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
