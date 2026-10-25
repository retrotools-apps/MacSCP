import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

@Suite("Release metadata")
struct ReleasePreparationTests {
    @Test func sourceLaunchUsesCanonicalVersionAcrossSurfaces() throws {
        let expected = try String(contentsOf: ReleaseMetadata.sourceRoot.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ReleaseMetadata().version == expected)
        #expect(AboutContent().version == expected)
        #expect(DiagnosticsViewModel.bundleVersion == expected)
        let notes = try #require(ChangelogResource.load())
        let release = try #require(ChangelogParser.parse(notes).first)
        #expect(release.version == expected)
        #expect(!release.sections.flatMap(\.entries).isEmpty)
    }

    @Test func packagedMetadataAndChangelogPrecedeTheCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "retroTools.release-fixture", "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "42"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Info.plist"))
        try Data("packaged notes".utf8).write(to: root.appendingPathComponent("CHANGELOG.md"))
        let bundle = try #require(Bundle(url: root))
        let metadata = ReleaseMetadata(bundle: bundle)
        #expect(metadata.version == "9.8.7")
        #expect(metadata.build == "42")
        #expect(ChangelogResource.load(bundle: bundle) == "packaged notes")
    }

    @Test func laterReleaseEntriesDoNotInheritVersionOneTranslations() {
        let entry = ChangelogRelease.Section.Entry(scope: "transfers", text: "A different future change")
        #expect(ReleaseNotesPresentation.entry(entry, version: "2.0.0").contains(entry.text))
        #expect(ReleaseNotesPresentation.sectionTitle("Other changes", version: "1.0.0") == "Other changes")
    }
}
