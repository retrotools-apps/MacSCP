import Foundation
import Testing
@testable import macSCPCore

@Suite("Automatic session import detection")
struct SessionImportDetectionTests {
    @Test(arguments: [false, true])
    func detectsNativeSessionsBeforeThePasswordIsKnown(encrypted: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "format": "macscp-sessions", "version": 2, "encrypted": encrypted,
        ])
        #expect(try SessionImportDetection.detect(data) == .macscp)
        // Routing does not bypass the real decoder's envelope validation.
        var rejected = false
        do { _ = try SessionExportCodec.decode(data, password: "synthetic") }
        catch SessionExportError.notAnExportFile { rejected = true }
        #expect(rejected)
    }

    @Test func detectsNativeLoginExports() throws {
        let data = Data(#"{"format":"macscp-logins","version":1}"#.utf8)
        #expect(try SessionImportDetection.detect(data) == .macscpLogins)
    }

    @Test func detectsWinSCPWithoutDecryptingAnything() throws {
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252] {
            let data = try #require("[Sessions\\Example]\nHostName=unit.example\n".data(using: encoding))
            #expect(try SessionImportDetection.detect(data) == .winscp)
            // Recognizing the format never relaxes the master requirement.
            var rejected = false
            do { _ = try WinSCPINICodec.decode(data, masterPassword: "synthetic") }
            catch WinSCPINIError.masterRequired { rejected = true }
            #expect(rejected)
        }
    }

    @Test func detectsXMLAndBinaryCyberduckBookmarks() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Protocol": "sftp", "Hostname": "unit.example"], format: format, options: 0)
            #expect(try SessionImportDetection.detect(data) == .cyberduck)
        }
    }

    @Test func rejectsUnknownAndOversizedInputs() {
        for data in [Data(), Data("[Unrelated]\nValue=1".utf8), Data("{}".utf8),
                     Data("{\"format\":\"foreign\"}".utf8),
                     Data(repeating: 0, count: SessionImportDetection.maximumFileSize + 1)] {
            #expect(throws: SessionExportError.notAnExportFile) { try SessionImportDetection.detect(data) }
        }
    }

    @Test func cyberduckSourceAlsoAcceptsOneSelectedFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cyberduck/sftp-password.duck")
        let rows = try CyberduckBookmarkSource().read(from: file)
        #expect(rows.count == 1)
        #expect(rows.first?.host == "sftp-password.example.net")
    }
}
