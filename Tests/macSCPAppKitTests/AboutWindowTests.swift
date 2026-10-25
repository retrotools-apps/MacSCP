import AppKit
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import MacSCPAppKit

@Suite("About window")
@MainActor
struct AboutWindowTests {
    @Test func developmentMetadataUsesCanonicalReleaseFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try #require(Bundle(url: directory))
        let content = AboutContent(bundle: bundle, sourceRoot: root)
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(content.version == version)
        #expect(content.licenseURL == root.appendingPathComponent("LICENSE"))
        #expect(content.noticesURL == root.appendingPathComponent("output/pdf/THIRD_PARTY_NOTICES.pdf"))
    }

    @Test func packagedVersionAndDocumentsTakePrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let packagedVersion = "9.8.7"
        let plist: [String: Any] = ["CFBundleIdentifier": "retroTools.about-fixture", "CFBundleShortVersionString": packagedVersion]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(FileManager.default.createFile(atPath: root.appendingPathComponent("Info.plist").path, contents: data))
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.pdf"] {
            #expect(FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("fixture".utf8)))
        }
        let source = root.appendingPathComponent("source")
        let sourcePDF = source.appendingPathComponent("output/pdf/THIRD_PARTY_NOTICES.pdf")
        try FileManager.default.createDirectory(at: sourcePDF.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("0.0.0".utf8).write(to: source.appendingPathComponent("VERSION"))
        try Data("source licence".utf8).write(to: source.appendingPathComponent("LICENSE"))
        try Data("source notices".utf8).write(to: sourcePDF)
        let bundle = try #require(Bundle(url: root))
        let content = AboutContent(bundle: bundle, sourceRoot: source)
        #expect(content.version == packagedVersion)
        #expect(content.licenseURL == bundle.url(forResource: "LICENSE", withExtension: nil))
        #expect(content.noticesURL == bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "pdf"))
    }

    @Test func missingMetadataDoesNotInventAVersionOrDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = AboutContent(bundle: try #require(Bundle(url: root)), sourceRoot: root)
        #expect(content.version == nil)
        #expect(content.licenseURL == nil)
        #expect(content.noticesURL == nil)
    }

    @Test func aLegacyPackagedLicenceStillPrecedesTheSourceCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("LICENSE")
        try Data("legacy packaged licence".utf8).write(to: url)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let content = AboutContent(bundle: try #require(Bundle(url: root)), sourceRoot: source)
        #expect(content.licenseURL == url)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func rendersInBothAppearances(scheme: ColorScheme) throws {
        let icon = try #require(ApplicationIcon.load())
        #expect(icon.size.width > 0 && icon.size.height > 0)
        let renderer = ImageRenderer(content: AboutView().environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test func legalDocumentIsAReadablePDFWithDependencyBookmarks() throws {
        let content = AboutContent()
        let url = try #require(content.noticesURL)
        #expect(url.pathExtension == "pdf")
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount > 0)
        let outline = try #require(document.outlineRoot)
        #expect(outline.numberOfChildren > 0)
        let text = try #require(document.string)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
