import CryptoKit
import Foundation

// Verify using only the embedded public key, never the signing secret.
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "MacSCPAppcast", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let arguments = CommandLine.arguments
    try require(arguments.count == 5, "usage: verify-appcast.swift <feed> <archive> <app> <public-key-file>")
    let feed = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let archiveURL = URL(fileURLWithPath: arguments[2])
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    let app = URL(fileURLWithPath: arguments[3])
    let publicText = try String(contentsOfFile: arguments[4], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicText) ?? Data())
    let infoData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] ?? [:]
    try require(info["SUPublicEDKey"] as? String == publicText, "Application update key does not match the release key")
    try require(info["SURequireSignedFeed"] as? Bool == true && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
                "Application must require signed feeds and archive verification")
    guard let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String else {
        throw NSError(domain: "MacSCPAppcast", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing application version"])
    }

    // Sparkle 2.9 appends a signature block after the exact signed XML bytes.
    // Accept only the format emitted by our pinned generate_appcast tool.
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: marker) else {
        throw NSError(domain: "MacSCPAppcast", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unsigned appcast rejected"])
    }
    let content = Data(feed[..<range.lowerBound])
    let block = String(decoding: feed[range.upperBound...], as: UTF8.self)
    let lines = block.components(separatedBy: "\n")
    try require(lines.count == 4 && lines[0].hasPrefix("edSignature: ") &&
                lines[1] == "length: \(content.count)" && lines[2] == "-->" && lines[3].isEmpty,
                "Malformed appcast signature block")
    let feedSignature = Data(base64Encoded: String(lines[0].dropFirst("edSignature: ".count))) ?? Data()
    try require(key.isValidSignature(feedSignature, for: content), "Appcast signature verification failed")

    let document = try XMLDocument(data: content, options: [.nodeLoadExternalEntitiesNever])
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Release feed must contain exactly the current release")
    let enclosures = try document.nodes(forXPath: "/rss/channel/item/enclosure")
    try require(enclosures.count == 1, "Missing or ambiguous update archive")
    guard let enclosure = enclosures.first as? XMLElement else {
        throw NSError(domain: "MacSCPAppcast", code: 1)
    }
    let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let signatureText = enclosure.attribute(forLocalName: "edSignature", uri: namespace)?.stringValue ?? ""
    let archiveSignature = Data(base64Encoded: signatureText) ?? Data()
    try require(key.isValidSignature(archiveSignature, for: archive), "Archive signature verification failed")
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "Archive length mismatch")
    let expectedURL = "https://github.com/retrotools-apps/MacSCP/releases/download/v\(version)/\(archiveURL.lastPathComponent)"
    try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL, "Unexpected update download URL")
    let children = items[0].children ?? []
    let versionNode = children.filter { $0.localName == "version" && $0.uri == namespace }
    let shortNode = children.filter { $0.localName == "shortVersionString" && $0.uri == namespace }
    try require(versionNode.count == 1 && versionNode.first?.stringValue == build &&
                shortNode.count == 1 && shortNode.first?.stringValue == version, "Feed and application versions differ")
    print("Verified Sparkle feed and archive against the application's public key")
} catch {
    // Do not print inputs or underlying tool diagnostics that may contain secrets.
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
