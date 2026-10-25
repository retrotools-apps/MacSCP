import Foundation

/// Content-based routing only. Each format's own decoder still validates
/// structure, version and credentials before any records are imported.
public enum SessionImportDetection {
    public enum Format: Equatable, Sendable {
        case macscp, macscpLogins, winscp, cyberduck
    }

    public static let maximumFileSize = 16 * 1024 * 1024

    public static func detect(_ data: Data) throws -> Format {
        guard data.count <= maximumFileSize else { throw SessionExportError.notAnExportFile }
        if let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if header["format"] as? String == "macscp-sessions" { return .macscp }
            if header["format"] as? String == "macscp-logins" { return .macscpLogins }
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let bookmark = plist as? [String: Any],
           bookmark["Protocol"] is String, bookmark["Hostname"] is String {
            return .cyberduck
        }
        if let sections = try? WinSCPINICodec.parse(data),
           sections.keys.contains(where: { $0.hasPrefix("Sessions\\") || $0 == "Configuration\\Security" }) {
            return .winscp
        }
        throw SessionExportError.notAnExportFile
    }
}
