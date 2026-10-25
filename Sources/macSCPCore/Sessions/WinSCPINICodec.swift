import Foundation

public enum WinSCPINIError: Error, LocalizedError, Sendable {
    case invalid, masterRequired, wrongMaster, unsupported, missingSecret, crypto
    public var errorDescription: String? {
        let key: String
        switch self {
        case .invalid: key = "core.winscp.invalid"
        case .masterRequired: key = "core.winscp.masterRequired"
        case .wrongMaster: key = "core.winscp.wrongMaster"
        case .unsupported: key = "core.winscp.unsupported"
        case .missingSecret: key = "core.winscp.missingSecret"
        case .crypto: key = "core.winscp.crypto"
        }
        return CoreL10n.string(key)
    }
}

/// Connection settings only; never executes imported proxy commands or trusts
/// imported host-key caches. Unsupported routes are excluded before import.
public enum WinSCPINICodec {
    public static let maximumFileSize = 16 * 1024 * 1024
    private static let keyNames = Dictionary(uniqueKeysWithValues: [
        "UseMasterPassword", "MasterPasswordVerifier", "FSProtocol", "ProxyMethod", "TunnelPortFwd",
        "EncryptKey", "PostLoginCommands", "HostName", "UserName", "PortNumber", "PublicKeyFile",
        "Password", "Passphrase", "Tunnel", "TunnelHostName", "TunnelPortNumber", "TunnelUserName",
        "TunnelPublicKeyFile", "TunnelPassword", "TunnelPassphrase", "PasswordPlain", "TunnelPasswordPlain",
        "ProxyPassword", "TryAgent"
    ].map { ($0.lowercased(), $0) })
    public struct ImportResult: Sendable {
        public let payload: SessionExportPayload
        public let skippedNames: [String]
    }

    static func parse(_ data: Data) throws -> [String: [String: String]] {
        guard data.count <= maximumFileSize else { throw WinSCPINIError.invalid }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) }
        guard let text, !text.contains("\0") else { throw WinSCPINIError.invalid }
        var sections: [String: [String: String]] = [:]
        var section: String?
        var seenSections: Set<String> = []
        var lineCount = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount.isMultiple(of: 1000) { try Task.checkCancellation() }
            guard lineCount <= 200_000, rawLine.utf8.count <= 65536 else { throw WinSCPINIError.invalid }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw WinSCPINIError.invalid }
                let rawName = String(line.dropFirst().dropLast())
                let folded = rawName.lowercased()
                // Caches and application preferences are deliberately not
                // imported. Windows INI section/key matching is case-insensitive.
                guard folded == "configuration\\security" || folded.hasPrefix("sessions\\") else { section = nil; continue }
                guard seenSections.insert(folded).inserted, sections.count < 10_000 else { throw WinSCPINIError.invalid }
                let name: String
                if folded == "configuration\\security" { name = "Configuration\\Security" }
                else if folded == "sessions\\default%20settings" { name = "Sessions\\Default%20Settings" }
                else { name = "Sessions\\" + rawName.dropFirst(9) }
                section = name
                sections[name] = [:]
            } else if let section, let equals = line.firstIndex(of: "=") {
                let rawKey = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let key = keyNames[rawKey.lowercased()] ?? rawKey.lowercased()
                guard !key.isEmpty, sections[section]?[key] == nil else { throw WinSCPINIError.invalid }
                sections[section]?[key] = String(line[line.index(after: equals)...])
            }
        }
        return sections
    }

    // WinSCP uses PuTTY-style percent escaping, with a UTF-8 BOM for Unicode
    // values. Legacy unmarked values use Windows ANSI (CP1252 here).
    static func decodeString(_ value: String) throws -> String {
        let input = Array(value.utf8)
        var bytes = Data()
        var index = 0
        while index < input.count {
            if input[index] == 37 {
                guard index + 2 < input.count,
                      let pair = String(bytes: input[index+1...index+2], encoding: .ascii) else { throw WinSCPINIError.invalid }
                bytes.append(try WinSCPPasswordCipher.unhex(pair))
                index += 3
            } else { bytes.append(input[index]); index += 1 }
        }
        let result: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { result = String(data: bytes.dropFirst(3), encoding: .utf8) }
        else { result = String(data: bytes, encoding: .windowsCP1252) }
        guard let result, !result.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw WinSCPINIError.invalid }
        return result
    }

    static func encodeString(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw WinSCPINIError.unsupported }
        var bytes = Array(value.utf8)
        if !value.unicodeScalars.allSatisfy(\.isASCII) { bytes = [0xEF, 0xBB, 0xBF] + bytes }
        return bytes.map { byte in
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45,46,95].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    public static func decode(_ data: Data, masterPassword: String) throws -> ImportResult {
        guard !masterPassword.isEmpty else { throw WinSCPINIError.masterRequired }
        let sections = try parse(data)
        guard let security = sections["Configuration\\Security"], security["UseMasterPassword"] == "1",
              let verifier = security["MasterPasswordVerifier"] else { throw WinSCPINIError.masterRequired }
        try WinSCPPasswordCipher.verify(verifier, master: masterPassword)
        var sessions: [ExportedSession] = []
        var skipped: [String] = []
        var groups: [ExportedGroup] = []
        var groupIDs: [String: UUID] = [:]
        let defaults = sections["Sessions\\Default%20Settings"] ?? [:]
        for section in sections.keys.sorted() where section.hasPrefix("Sessions\\") && section != "Sessions\\Default%20Settings" {
            try Task.checkCancellation()
            let path = try decodeString(String(section.dropFirst(9)))
            let row = defaults.merging(sections[section] ?? [:]) { _, actual in actual }
            // Proxies, local commands, extra port forwards and encrypted remote
            // filenames have no faithful MacSCP equivalent. Never bypass them.
            if !["0", "1", "2"].contains(row["FSProtocol"] ?? "1") ||
                !["0", "none", ""].contains((row["ProxyMethod"] ?? "0").lowercased()) ||
                !(row["TunnelPortFwd"] ?? "").isEmpty || !(row["EncryptKey"] ?? "").isEmpty ||
                !(row["PostLoginCommands"] ?? "").isEmpty {
                skipped.append(path)
                continue
            }
            func value(_ key: String) throws -> String { try decodeString(row[key] ?? "") }
            func port(_ key: String) throws -> Int {
                guard let port = Int(row[key] ?? "22"), (1...65535).contains(port) else { throw WinSCPINIError.invalid }
                return port
            }
            func secret(_ key: String, legacyKey: String) throws -> String? {
                try WinSCPPasswordCipher.decrypt(value(key), master: masterPassword, legacyKey: legacyKey)
            }
            let host = try value("HostName"), username = try value("UserName")
            let key = try value("PublicKeyFile")
            // A saved key plus a fallback password requires an authentication
            // chain MacSCP does not represent. Do not silently lose a secret.
            if !key.isEmpty && !(row["Password"] ?? "").isEmpty { skipped.append(path); continue }
            if ["PasswordPlain", "TunnelPasswordPlain", "ProxyPassword"].contains(where: { !(row[$0] ?? "").isEmpty }) {
                throw WinSCPINIError.invalid
            }
            var values = SSHFieldSchema.defaults
            values[SSHField.host] = host
            values[SSHField.port] = String(try port("PortNumber"))
            values[SSHField.username] = username
            let agentOnly = key.isEmpty && (row["Password"] ?? "").isEmpty && row["TryAgent"] == "1"
            values[SSHField.authKind] = !key.isEmpty ? "privateKey" : (agentOnly ? "agent" : "password")
            values[SSHField.keyPath] = key
            let password = try secret(key.isEmpty ? "Password" : "Passphrase", legacyKey: key.isEmpty ? username + host : key)
            var jumpHost: String?, jumpPort: Int?, jumpUser: String?, jumpKind: StoredSession.AuthKind?, jumpKey: String?, jumpSecret: String?
            if row["Tunnel"] == "1" {
                jumpHost = try value("TunnelHostName")
                jumpPort = try port("TunnelPortNumber")
                jumpUser = try value("TunnelUserName")
                let keyPath = try value("TunnelPublicKeyFile")
                if !keyPath.isEmpty && !(row["TunnelPassword"] ?? "").isEmpty { skipped.append(path); continue }
                let jumpAgent = keyPath.isEmpty && (row["TunnelPassword"] ?? "").isEmpty && row["TryAgent"] == "1"
                jumpKind = !keyPath.isEmpty ? .privateKey : (jumpAgent ? .agent : .password)
                jumpKey = keyPath.isEmpty ? nil : keyPath
                jumpSecret = try secret(keyPath.isEmpty ? "TunnelPassword" : "TunnelPassphrase", legacyKey: keyPath.isEmpty ? (jumpUser ?? "") + (jumpHost ?? "") : keyPath)
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.last, !name.isEmpty, !parts.contains("") else { throw WinSCPINIError.invalid }
            var parent: UUID?
            var prefix = ""
            for component in parts.dropLast() {
                prefix += "/" + component
                if let existing = groupIDs[prefix] { parent = existing }
                else {
                    let id = UUID()
                    groups.append(ExportedGroup(id: id, name: component, parentID: parent))
                    groupIDs[prefix] = id
                    parent = id
                }
            }
            sessions.append(ExportedSession(id: UUID(), name: name, kind: .ssh, fields: values.raw,
                groupID: parent, password: password, jumpHost: jumpHost, jumpPort: jumpPort,
                jumpUsername: jumpUser, jumpAuthKind: jumpKind, jumpKeyPath: jumpKey, jumpPassword: jumpSecret,
                importSource: "winscp", importID: section, importedAt: Date()))
        }
        return ImportResult(payload: SessionExportPayload(includesSecrets: true, groups: groups, sessions: sessions), skippedNames: skipped)
    }

    public static func supportsExport(_ session: StoredSession, sessions: [StoredSession] = []) -> Bool {
        let jumpTLS: Bool
        if let id = session.jump?.sessionID {
            guard let saved = sessions.first(where: { $0.id == id }) else { return false }
            jumpTLS = saved.ssh?.tlsTunnel != nil
        } else {
            jumpTLS = session.jump?.tlsTunnel != nil
        }
        return session.kind == .ssh && session.ssh != nil && session.ssh?.tlsTunnel == nil
            && session.ssh?.authKind != .privateKey && !jumpTLS
    }

    public static func selecting(_ ids: Set<UUID>, from original: SessionExportPayload) -> SessionExportPayload {
        var payload = original
        payload.sessions = payload.sessions.filter { ids.contains($0.id) }
        let groups = Dictionary(payload.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included: Set<UUID> = []
        for session in payload.sessions {
            var parent = session.groupID
            while let id = parent, included.insert(id).inserted { parent = groups[id]?.parentID }
        }
        payload.groups = payload.groups.filter { included.contains($0.id) }
        return payload
    }

    public static func encode(_ payload: SessionExportPayload, masterPassword: String) throws -> Data {
        guard !masterPassword.isEmpty else { throw WinSCPINIError.masterRequired }
        guard payload.includesSecrets, !payload.sessions.isEmpty else { throw WinSCPINIError.missingSecret }
        var lines = ["[Configuration\\Security]", "UseMasterPassword=1",
                     "MasterPasswordVerifier=" + (try WinSCPPasswordCipher.verifier(master: masterPassword)), ""]
        let groups = Dictionary(payload.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: Set<String> = []
        var secretCount = 0
        for session in payload.sessions {
            try Task.checkCancellation()
            guard session.kind == nil || session.kind == .ssh else { throw WinSCPINIError.unsupported }
            let values = FieldValues(raw: session.fields)
            guard values[SSHField.tlsEnabled] != "true", session.jumpTLSTunnel == nil else {
                throw WinSCPINIError.unsupported
            }
            var path = session.name
            var parent = session.groupID
            var visited: Set<UUID> = []
            while let id = parent {
                guard visited.insert(id).inserted, let group = groups[id], !group.name.contains("/") else { throw WinSCPINIError.unsupported }
                path = group.name + "/" + path
                parent = group.parentID
            }
            guard !session.name.isEmpty, !session.name.contains("/"), names.insert(path.lowercased()).inserted else { throw WinSCPINIError.unsupported }
            // Explicit route resets prevent an existing WinSCP Default Settings
            // profile from injecting a proxy, tunnel or unrelated key file.
            lines += ["[Sessions\\" + (try encodeString(path)) + "]", "FSProtocol=2", "ProxyMethod=0", "PublicKeyFile="]
            func append(_ key: String, _ value: String) throws { lines.append(key + "=" + (try encodeString(value))) }
            func appendSecret(_ key: String, _ value: String?) throws {
                if let value, !value.isEmpty {
                    lines.append(key + "=" + (try WinSCPPasswordCipher.encrypt(value, master: masterPassword)))
                    secretCount += 1
                }
            }
            try append("HostName", values[SSHField.host])
            try append("PortNumber", values[SSHField.port].isEmpty ? "22" : values[SSHField.port])
            try append("UserName", values[SSHField.username])
            let auth = StoredSession.AuthKind(rawValue: values[SSHField.authKind]) ?? .password
            if auth == .privateKey {
                // WinSCP's saved-site format does not persist key passphrases
                // portably. Refuse instead of omitting one requested for export.
                throw WinSCPINIError.unsupported
            } else if auth == .password {
                lines.append("TryAgent=0")
                guard let secret = session.password, !secret.isEmpty else { throw WinSCPINIError.missingSecret }
                try appendSecret("Password", secret)
            } else { lines.append("TryAgent=1") }
            if let host = session.jumpHost {
                lines.append("Tunnel=1")
                try append("TunnelHostName", host)
                try append("TunnelPortNumber", String(session.jumpPort ?? 22))
                try append("TunnelUserName", session.jumpUsername ?? "")
                if session.jumpAuthKind == .privateKey {
                    throw WinSCPINIError.unsupported
                } else if session.jumpAuthKind == .agent {
                    // WinSCP shares TryAgent between the target and tunnel;
                    // a password target with an agent-only jump cannot keep
                    // MacSCP's per-hop authentication choices faithfully.
                    guard auth == .agent else { throw WinSCPINIError.unsupported }
                } else {
                    guard let secret = session.jumpPassword, !secret.isEmpty else { throw WinSCPINIError.missingSecret }
                    try appendSecret("TunnelPassword", secret)
                }
            } else { lines.append("Tunnel=0") }
            lines.append("")
        }
        let result = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        guard secretCount > 0 else { throw WinSCPINIError.missingSecret }
        guard result.count <= maximumFileSize else { throw WinSCPINIError.invalid }
        return result
    }
}
