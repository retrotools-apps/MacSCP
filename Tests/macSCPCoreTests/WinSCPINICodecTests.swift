import Foundation
import Testing
@testable import macSCPCore

@Suite("WinSCP master-password compatibility")
struct WinSCPINICodecTests {
    // Independent Python hashlib/HMAC + OpenSSL AES-ECB vectors based on the
    // WinSCP Cryptography.cpp format at 24e7b4ec1001406cc2edf2b8c88483d66d4449d8.
    private let master = "fixture-master-🔑"
    private let verifier = "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1FBA87AF9D94AE9A734725"
    private let ciphertext = "A35D000102030405060708090A0B0C0D0E0F5BE95A04FDF07BD0FEED62F741F9370D64EA30F24E039067B73D31D25C3C889CF3C8D24D3D787F204C89D14C"

    @Test func independentAESAndVerifierVectorsMatch() throws {
        let plaintext = Data((0...32).map(UInt8.init))
        let salt = Data((0...15).map(UInt8.init))
        let expected = try WinSCPPasswordCipher.unhex("000102030405060708090A0B0C0D0E0F5DC87E4C683D9FE548DBB9842EB24BB05C2024F827AE2C183FE5906CDCAF5191B0403FA0F4A01BA972096E")
        let sealed = try WinSCPPasswordCipher.seal(plaintext, master: master, salt: salt)
        #expect(sealed == expected)
        #expect(try WinSCPPasswordCipher.open(expected, master: master) == plaintext)
        let generated = try WinSCPPasswordCipher.verifier(master: master, salt: salt, dummy: Data((16...31).map(UInt8.init)))
        #expect(generated == verifier)
        try WinSCPPasswordCipher.verify(verifier, master: master)
        let wrongMaster = "wrong-fixture"
        #expect(throws: WinSCPINIError.wrongMaster) { try WinSCPPasswordCipher.verify(verifier, master: wrongMaster) }
    }

    @Test func upstreamScramblingVectorDecrypts() throws {
        let expected = "fixture-secret-€"
        let decrypted = try WinSCPPasswordCipher.decrypt(ciphertext, master: master, legacyKey: "unused")
        let matches = decrypted == expected
        #expect(matches)
        for secret in [expected, "abc", String(repeating: "x", count: 999), "12345678901234", "🔐日本語"] {
            let generated = try WinSCPPasswordCipher.encrypt(secret, master: master)
            let actual = try WinSCPPasswordCipher.decrypt(generated, master: master, legacyKey: "unused")
            let matches = actual == secret
            #expect(matches)
            #expect(generated.hasPrefix("A35D"))
        }
    }

    @Test func tamperingAndWrongMastersNeverYieldPlaintext() throws {
        let wrongMaster = "wrong-fixture"
        #expect(throws: WinSCPINIError.wrongMaster) {
            try WinSCPPasswordCipher.decrypt(ciphertext, master: wrongMaster, legacyKey: "unused")
        }
        var bytes = try WinSCPPasswordCipher.unhex(String(ciphertext.dropFirst(4)))
        bytes[20] ^= 1
        #expect(throws: WinSCPINIError.wrongMaster) { try WinSCPPasswordCipher.open(bytes, master: master) }
        #expect(throws: WinSCPINIError.invalid) { try WinSCPPasswordCipher.unhex("0G") }
        #expect(throws: WinSCPINIError.invalid) { try WinSCPPasswordCipher.unhex("0") }
        let invalidSecret = "fixture\0secret"
        #expect(throws: WinSCPINIError.unsupported) { try WinSCPPasswordCipher.encrypt(invalidSecret, master: master) }
    }

    private func ini(_ body: String) -> Data {
        Data(("[Configuration\\Security]\nUseMasterPassword=1\nMasterPasswordVerifier=\(verifier)\n" + body).utf8)
    }

    @Test func independentINIImportsSecretsFoldersAndJumpWithoutRunningProxyCommands() throws {
        let data = ini("""
        [Sessions\\Folder%2FUnit]
        HostName=host.example
        UserName=user
        Password=\(ciphertext)
        Tunnel=1
        TunnelHostName=jump.example
        TunnelUserName=jump-user
        TunnelPortNumber=2222
        TunnelPassword=\(ciphertext)
        [Sessions\\NotSupported]
        HostName=do-not-contact.example
        ProxyMethod=5
        ProxyTelnetCommand=must-not-execute
        """)
        let result = try WinSCPINICodec.decode(data, masterPassword: master)
        #expect(result.payload.sessions.count == 1)
        #expect(result.skippedNames == ["NotSupported"])
        let session = try #require(result.payload.sessions.first)
        #expect(session.name == "Unit")
        #expect(result.payload.groups.first?.name == "Folder")
        #expect(session.jumpHost == "jump.example")
        #expect(session.jumpPort == 2222)
        let expected = "fixture-secret-€"
        let secretsMatch = session.password == expected && session.jumpPassword == expected
        #expect(secretsMatch)
        #expect(!session.fields.keys.contains(where: { $0.lowercased().contains("password") }))
    }

    @Test func exportAlwaysIncludesEncryptedSecretsAndRequiresMaster() throws {
        let imported = try WinSCPINICodec.decode(ini("""
        [Sessions\\Unit]
        HostName=host.example
        UserName=user
        Password=\(ciphertext)
        Tunnel=1
        TunnelHostName=jump.example
        TunnelUserName=jump-user
        TunnelPassword=\(ciphertext)
        """), masterPassword: master).payload
        let encoded = try WinSCPINICodec.encode(imported, masterPassword: master)
        let text = try #require(String(data: encoded, encoding: .utf8))
        let expected = "fixture-secret-€"
        let excludesPlaintext = !text.contains(expected) && !text.contains(master)
        #expect(excludesPlaintext)
        #expect(text.contains("UseMasterPassword=1"))
        #expect(text.contains("Password=A35D"))
        #expect(text.contains("ProxyMethod=0"))
        #expect(text.contains("TryAgent=0"))
        #expect(!text.contains("PasswordPlain="))
        let result = try WinSCPINICodec.decode(encoded, masterPassword: master)
        let secretsMatch = result.payload.sessions.first?.password == expected && result.payload.sessions.first?.jumpPassword == expected
        #expect(secretsMatch)
        #expect(throws: WinSCPINIError.masterRequired) { try WinSCPINICodec.encode(imported, masterPassword: "") }
        var withoutSecrets = imported
        withoutSecrets.includesSecrets = false
        #expect(throws: WinSCPINIError.missingSecret) { try WinSCPINICodec.encode(withoutSecrets, masterPassword: master) }
        var missingSecret = imported
        missingSecret.sessions[0].password = nil
        #expect(throws: WinSCPINIError.missingSecret) { try WinSCPINICodec.encode(missingSecret, masterPassword: master) }
    }

    @Test func unsupportedRoutesNeverBecomeDirectConnections() throws {
        for proxy in ["1", "2", "3", "4", "5", "cmd", "http", "socks5"] {
            let result = try WinSCPINICodec.decode(ini("[Sessions\\Unit]\nHostName=host\nProxyMethod=\(proxy)\n"), masterPassword: master)
            #expect(result.payload.sessions.isEmpty)
            #expect(result.skippedNames.count == 1)
        }
        let payload = try WinSCPINICodec.decode(ini("[Sessions\\Unit]\nHostName=host\nUserName=user\nPassword=\(ciphertext)\n"), masterPassword: master).payload
        var withTLS = payload
        withTLS.sessions[0].fields["SSHField.tlsEnabled"] = "true"
        #expect(throws: WinSCPINIError.unsupported) { try WinSCPINICodec.encode(withTLS, masterPassword: master) }
    }

    @Test func malformedOrUnprotectedFilesAreRejectedBeforeImport() throws {
        #expect(throws: WinSCPINIError.masterRequired) { try WinSCPINICodec.decode(Data("[Sessions\\x]".utf8), masterPassword: master) }
        #expect(throws: WinSCPINIError.invalid) { try WinSCPINICodec.parse(Data("[Sessions\\x]\nHostName=a\nHostName=b".utf8)) }
        #expect(throws: WinSCPINIError.invalid) { try WinSCPINICodec.parse(Data("[Sessions\\x]\n[Sessions\\x]".utf8)) }
        #expect(throws: WinSCPINIError.invalid) { try WinSCPINICodec.decode(ini("[Sessions\\x]\nHostName=bad%0Ahost"), masterPassword: master) }
        #expect(throws: WinSCPINIError.invalid) { try WinSCPINICodec.parse(Data(repeating: 0, count: WinSCPINICodec.maximumFileSize + 1)) }
    }

    @Test func unicodeAndPercentEscapesRoundTripWithoutTreatingPlusAsSpace() throws {
        for text in ["Folder/日本語 €", "host+user", "%2F", "C:\\Users\\Unit\\key.ppk"] {
            #expect(try WinSCPINICodec.decodeString(WinSCPINICodec.encodeString(text)) == text)
        }
        #expect(try WinSCPINICodec.decodeString("caf%E9") == "café")
    }

    @Test func windowsINICaseRulesCannotBypassUnsafeRouteDetection() throws {
        let result = try WinSCPINICodec.decode(ini("[sessions\\Unit]\nhostname=host\nproxymethod=5\n"), masterPassword: master)
        #expect(result.payload.sessions.isEmpty)
        #expect(result.skippedNames == ["Unit"])
        #expect(throws: WinSCPINIError.invalid) { try WinSCPINICodec.parse(Data("[sessions\\Unit]\nHostName=a\nhostname=b".utf8)) }
    }

    @Test func legacyObfuscationIsAcceptedOnlyInsideAVerifiedMasterProtectedFile() throws {
        let expected = "legacy-fixture"
        let key = "userhost"
        let plain = Array((key + expected).utf8)
        let header: [UInt8] = [255, 0, UInt8(plain.count), 0]
        let encoded = WinSCPPasswordCipher.hex(Data((header + plain).map { (~$0) ^ 0xA3 }))
        let decoded = try WinSCPPasswordCipher.decrypt(encoded, master: master, legacyKey: key)
        let matches = decoded == expected
        #expect(matches)
        #expect(throws: WinSCPINIError.invalid) { try WinSCPPasswordCipher.decrypt(encoded, master: master, legacyKey: "different") }
    }

    @Test func importingASelectionDoesNotCreateUnselectedFolders() {
        let first = ExportedGroup(id: UUID(), name: "First")
        let second = ExportedGroup(id: UUID(), name: "Second")
        let selected = ExportedSession(id: UUID(), name: "Selected", groupID: first.id)
        let other = ExportedSession(id: UUID(), name: "Other", groupID: second.id)
        let payload = SessionExportPayload(includesSecrets: true, groups: [first, second], sessions: [selected, other])
        let result = WinSCPINICodec.selecting([selected.id], from: payload)
        #expect(result.sessions.count == 1)
        #expect(result.groups == [first])
    }

    @Test func agentCompanionsKeepTheirAuthenticationModeButCannotCreateASecretFreeExport() throws {
        let passwordPayload = try WinSCPINICodec.decode(ini("[Sessions\\Password]\nHostName=host\nUserName=user\nPassword=\(ciphertext)\n"), masterPassword: master).payload
        var fields = SSHFieldSchema.defaults
        fields[SSHField.host] = "agent.example"
        fields[SSHField.username] = "user"
        fields[SSHField.authKind] = "agent"
        let agent = ExportedSession(id: UUID(), name: "Agent", kind: .ssh, fields: fields.raw)
        var payload = passwordPayload
        payload.sessions.append(agent)
        let result = try WinSCPINICodec.decode(WinSCPINICodec.encode(payload, masterPassword: master), masterPassword: master)
        let importedAgent = try #require(result.payload.sessions.first { $0.name == "Agent" })
        #expect(importedAgent.fields["SSHField.authKind"] == "agent")
        let withoutSecrets = SessionExportPayload(includesSecrets: true, groups: [], sessions: [agent])
        #expect(throws: WinSCPINIError.missingSecret) { try WinSCPINICodec.encode(withoutSecrets, masterPassword: master) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_WINSCP_STRUCTURE_FILE"] != nil))
    func operatorSelectedFileIsStructurallyReadableWithoutDecryptingSecrets() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACSCP_WINSCP_STRUCTURE_FILE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try WinSCPINICodec.parse(data)
        #expect(parsed["Configuration\\Security"]?["UseMasterPassword"] == "1")
        #expect(parsed.keys.contains { $0.hasPrefix("Sessions\\") })
    }
}
