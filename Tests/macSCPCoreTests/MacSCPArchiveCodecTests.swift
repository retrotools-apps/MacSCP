import Foundation
import Testing
@testable import macSCPCore

@Suite("MacSCPArchiveCodec")
struct MacSCPArchiveCodecTests {
    private func connections() -> SessionExportPayload {
        SessionExportPayload(
            includesSecrets: false, groups: [],
            sessions: [ExportedSession(
                id: UUID(), name: "Prod", kind: .ssh,
                fields: sshExportFields(host: "prod.example", username: "deploy"))])
    }

    private func loginSets(secret: String? = nil) -> LoginSetExportPayload {
        LoginSetExportPayload(
            includesSecrets: secret != nil, includesKeyFiles: false,
            sets: [ExportedLoginSet(
                id: UUID(), name: "Prod login", kind: .ssh, username: "deploy",
                authKind: .password, keyPath: nil, accessKeyID: nil,
                secret: secret, embeddedKey: nil)])
    }

    @Test func oneArchiveCarriesConnectionsAndLoginSets() throws {
        var archive = MacSCPArchiveBuilder.build(
            scope: .all, connections: connections(), includeIdentities: true,
            tunnels: [], tunnelGroups: [])
        archive = MacSCPArchiveBuilder.addingLoginSets(loginSets(), to: archive)
        let data = try MacSCPArchiveCodec.encode(archive, password: nil)
        let decoded = try MacSCPArchiveCodec.decode(data)
        #expect(decoded == archive)
        #expect(decoded.manifest.includesConnections)
        #expect(decoded.manifest.includesLoginSets)
        #expect(decoded.manifest.scope == .all)
    }

    @Test func loginOnlyArchiveUsesTheSameFormat() throws {
        let archive = MacSCPArchiveBuilder.loginSets(loginSets(secret: "secret"))
        let data = try MacSCPArchiveCodec.encode(archive, password: "pw")
        let decoded = try MacSCPArchiveCodec.decode(data, password: "pw")
        let exposesSecret = String(decoding: data, as: UTF8.self).contains("secret")
        #expect(try MacSCPArchiveCodec.probe(data))
        #expect(decoded == archive)
        #expect(!exposesSecret)
    }

    @Test func shareArchiveRemovesIdentitiesAndSecrets() throws {
        var source = connections()
        source.includesSecrets = true
        source.sessions[0].password = "secret"
        source.sessions.append(ExportedSession(
            id: UUID(), name: "WebDAV", kind: .webdav,
            fields: webdavExportFields(
                baseURL: "https://alice:url-secret@cloud.example/dav",
                username: "alice")))
        let archive = MacSCPArchiveBuilder.build(
            scope: .connection, connections: source, includeIdentities: false,
            tunnels: [], tunnelGroups: [])
        let data = try MacSCPArchiveCodec.encode(archive, password: nil)
        let decoded = try MacSCPArchiveCodec.decode(data)
        #expect(decoded.manifest.includesIdentities == false)
        #expect(decoded.manifest.includesSecrets == false)
        #expect(decoded.connections?.sessions.first?.password == nil)
        let fields = FieldValues(raw: decoded.connections?.sessions.first?.fields ?? [:])
        let cleartext = String(decoding: data, as: UTF8.self)
        let exposesSecret = cleartext.contains("secret")
        let exposesIdentity = cleartext.contains("alice")
        #expect(fields[SSHField.username] == "")
        #expect(!exposesSecret)
        #expect(!exposesIdentity)
    }

    @Test func manifestCannotHideSecrets() throws {
        var archive = MacSCPArchiveBuilder.loginSets(loginSets(secret: "secret"))
        archive.manifest.includesSecrets = false
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try MacSCPArchiveCodec.encode(archive, password: nil)
        }
    }
}
