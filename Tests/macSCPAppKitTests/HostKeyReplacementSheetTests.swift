import AppKit
import SwiftUI
import Testing
import MacSCPTestSupport
@testable import MacSCPAppKit
import macSCPCore

@MainActor
struct HostKeyReplacementSheetTests {
    @Test func replacementDialogFitsFullFingerprintsAndDoesNotMutateOnAppearance() async throws {
        _ = NSApplication.shared
        let candidate = HostKeyCandidate(host: "fixture.invalid", port: 2222, keyType: "ssh-ed25519",
            publicKeyBase64: Data("synthetic replacement dialog key".utf8).base64EncodedString())
        let old = KnownHostKey(host: candidate.host, port: candidate.port, keyType: candidate.keyType,
            publicKeyBase64: Data("synthetic saved dialog key".utf8).base64EncodedString())
        let change = HostKeyMismatchDetails(host: candidate.host, expected: old.fingerprintSHA256,
            presented: candidate.fingerprintSHA256, candidate: candidate)
        var replacements = 0
        let host = NSHostingView(rootView: HostKeyReplacementSheet(change: change,
            onReplace: { replacements += 1; return true }, onClose: {})
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(size.width >= 680)
        #expect(replacements == 0)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var redSamples = 0
        for x in stride(from: bitmap.pixelsWide / 2, to: bitmap.pixelsWide, by: 8) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                    redSamples += 1
                }
            }
        }
        #expect(redSamples > 20, "The replacement action must remain red, including in inactive windows")
        if ProcessInfo.processInfo.environment["MACSCP_HOSTKEY_PREVIEW"] == "1" {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/macscp-hostkey-replacement.png"))
        }
    }

    @Test func overviewAndFormBothUseTheReplacementPresentation() throws {
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        for name in ["SessionOverviewFailureAlert.swift", "ConnectionFormView.swift"] {
            let source = try SourceCorpus.code(of: root.appendingPathComponent(name))
            #expect(source.contains("HostKeyReplacementPresentation("))
            #expect(source.contains("lastHostKeyMismatch?.candidate == nil"))
        }
    }
}
