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

    @Test func archiveRoundTripPreservesPortableRelationshipIDs() throws {
        let setID = UUID()
        let jumpSetID = UUID()
        let jumpSessionID = UUID()
        var source = connections()
        source.sessions[0].loginSetID = setID
        source.sessions[0].jumpLoginSetID = jumpSetID
        source.sessions[0].jumpSessionID = jumpSessionID
        let archive = MacSCPArchiveBuilder.build(
            scope: .all, connections: source, includeIdentities: true,
            tunnels: [], tunnelGroups: [])

        let decoded = try MacSCPArchiveCodec.decode(
            MacSCPArchiveCodec.encode(archive, password: nil))
        let session = try #require(decoded.connections?.sessions.first)
        #expect(session.loginSetID == setID)
        #expect(session.jumpLoginSetID == jumpSetID)
        #expect(session.jumpSessionID == jumpSessionID)
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
        source.sessions[0].loginSetID = UUID()
        source.sessions[0].jumpLoginSetID = UUID()
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
        #expect(decoded.connections?.sessions.first?.loginSetID == nil)
        #expect(decoded.connections?.sessions.first?.jumpLoginSetID == nil)
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

    @Test func tunnelPreferencesAndTLSCarrierConfigurationRoundTrip() throws {
        let sessionID = UUID()
        let jumpID = UUID()
        let tls = try SSHTLSTunnelConfig(
            host: "gateway.example", port: 443, serverName: "ssh.example",
            verifyCertificate: true)
        var source = connections()
        source.sessions = [ExportedSession(
            id: sessionID, name: "TLS", kind: .ssh,
            fields: sshExportFields(host: "ssh.example", username: "deploy"),
            jumpHost: "gateway.example", jumpUsername: "deploy", jumpTLSTunnel: tls)]
        let tunnel = TunnelProfile(
            sessionID: sessionID, name: "Database",
            kind: .local(bind: "127.0.0.1", localPort: 5432, host: "db", remotePort: 5432),
            autoStart: .appStart, reconnects: true, service: .tcp,
            jumpSessionID: jumpID)
        let archive = MacSCPArchiveBuilder.build(
            scope: .all, connections: source, includeIdentities: true,
            tunnels: [tunnel], tunnelGroups: [])
        let decoded = try MacSCPArchiveCodec.decode(
            MacSCPArchiveCodec.encode(archive, password: nil))

        #expect(decoded.connections?.sessions.first?.jumpTLSTunnel == tls)
        #expect(decoded.tunnels.first?.autoStart == .appStart)
        #expect(decoded.tunnels.first?.reconnects == true)
        // The jump is outside the selected connection scope, so the builder
        // safely drops that dangling reference instead of serializing it.
        #expect(decoded.tunnels.first?.jumpSessionID == nil)
    }

    @Test func globalArchivePreservesEmptyTunnelGroupHierarchy() throws {
        let parent = TunnelGroup(name: "Infrastructure")
        let child = TunnelGroup(name: "Reserved", parentID: parent.id)
        let archive = MacSCPArchiveBuilder.build(
            scope: .all, connections: connections(), includeIdentities: true,
            tunnels: [], tunnelGroups: [parent, child])

        let decoded = try MacSCPArchiveCodec.decode(
            MacSCPArchiveCodec.encode(archive, password: nil))

        #expect(decoded.manifest.includesTunnels)
        #expect(decoded.tunnelGroups.map(\.name) == ["Infrastructure", "Reserved"])
        #expect(decoded.tunnelGroups[1].parentID == parent.id)
    }

    @Test func repeatedTunnelImportUsesTheSharedConflictDecisionAndExistingID() async throws {
        let sourceSessionID = UUID()
        let localSessionID = UUID()
        let portableID = UUID()
        let source = TunnelProfile(
            sessionID: sourceSessionID, name: "Database",
            kind: .local(bind: "127.0.0.1", localPort: 15432, host: "db", remotePort: 5432),
            portableID: portableID)
        let existing = TunnelProfile(
            sessionID: localSessionID, name: "Old database",
            kind: .local(bind: "127.0.0.1", localPort: 25432, host: "old", remotePort: 5432),
            portableID: portableID)
        let archive = MacSCPArchivePayload(
            manifest: MacSCPArchiveManifest(
                scope: .all, includesConnections: true, includesLoginSets: false,
                includesIdentities: true, includesSecrets: false,
                includesPrivateKeys: false, includesTunnels: true),
            connections: connections(), tunnels: [source])

        let plan = await MacSCPArchiveImportPlanner.tunnels(
            from: archive, sessionIDMap: [sourceSessionID: localSessionID],
            existingGroups: [], existingTunnels: [existing],
            arbiter: ImportConflictArbiter { conflict in
                #expect(conflict.kindLabel == MacSCPArchiveImportPlanner.tunnelKindLabel)
                return (.replace, true)
            })

        let replacement = try #require(plan.tunnels.first)
        #expect(replacement.id == existing.id)
        #expect(replacement.name == "Database")
        #expect(replacement.portableID == portableID)
        #expect(plan.replaced == ["Database"])
    }

    @Test func cancellingATunnelConflictPlansNothing() async {
        let sourceSessionID = UUID()
        let localSessionID = UUID()
        let source = TunnelProfile(
            sessionID: sourceSessionID, name: "Database",
            kind: .dynamic(bind: "127.0.0.1", localPort: 1080))
        let existing = TunnelProfile(
            sessionID: localSessionID, name: "Database",
            kind: .dynamic(bind: "127.0.0.1", localPort: 2080))
        let archive = MacSCPArchivePayload(
            manifest: MacSCPArchiveManifest(
                scope: .all, includesConnections: true, includesLoginSets: false,
                includesIdentities: true, includesSecrets: false,
                includesPrivateKeys: false, includesTunnels: true),
            connections: connections(), tunnels: [source])

        let plan = await MacSCPArchiveImportPlanner.tunnels(
            from: archive, sessionIDMap: [sourceSessionID: localSessionID],
            existingGroups: [], existingTunnels: [existing],
            arbiter: ImportConflictArbiter { _ in nil })
        #expect(plan.cancelled)
        #expect(plan.groups.isEmpty)
        #expect(plan.tunnels.isEmpty)
    }

    @Test func repeatedAnonymousImportUsesTheSharedConflictDecision() async throws {
        let portableID = UUID()
        var payload = connections()
        payload.sessions[0].portableID = portableID
        let archive = MacSCPArchiveBuilder.build(
            scope: .connection, connections: payload, includeIdentities: false,
            tunnels: [], tunnelGroups: [])
        let existing = StoredSession(
            name: "Local", ssh: .init(host: "old.invalid", username: "local"),
            portableID: portableID)

        let plan = await MacSCPArchiveImportPlanner.anonymousConnections(
            from: archive, existingSessions: [existing], existingGroups: [],
            arbiter: ImportConflictArbiter { conflict in
                #expect(conflict.kindLabel == MacSCPArchiveImportPlanner.anonymousSessionKindLabel)
                return (.replace, true)
            })

        let replacement = try #require(plan.sessions.first)
        #expect(replacement.id == existing.id)
        #expect(replacement.portableID == portableID)
        #expect(plan.replaced == ["Prod"])
    }

    @Test func cancellingAnAnonymousConflictPlansNoPersistentWrites() async {
        var payload = connections()
        let portableID = UUID()
        payload.sessions[0].portableID = portableID
        let archive = MacSCPArchiveBuilder.build(
            scope: .connection, connections: payload, includeIdentities: false,
            tunnels: [], tunnelGroups: [])
        let existing = StoredSession(
            name: "Local", ssh: .init(host: "old.invalid", username: "local"),
            portableID: portableID)

        let plan = await MacSCPArchiveImportPlanner.anonymousConnections(
            from: archive, existingSessions: [existing], existingGroups: [],
            arbiter: ImportConflictArbiter { _ in nil })

        #expect(plan.cancelled)
        #expect(plan.groups.isEmpty)
        #expect(plan.sessions.isEmpty)
        #expect(plan.sessionIDMap.isEmpty)
    }

    @Test func anonymousSessionDoesNotInheritCredentialFromAGroupKeptLocal() async throws {
        let sourceGroup = ExportedGroup(id: UUID(), name: "Production")
        var payload = connections()
        payload.groups = [sourceGroup]
        payload.sessions[0].groupID = sourceGroup.id
        let archive = MacSCPArchiveBuilder.build(
            scope: .group, connections: payload, includeIdentities: false,
            tunnels: [], tunnelGroups: [])
        let localGroup = StoredGroup(
            name: "Production", loginSetID: UUID(), sshRelaySessionID: UUID())

        let plan = await MacSCPArchiveImportPlanner.anonymousConnections(
            from: archive, existingSessions: [], existingGroups: [localGroup],
            arbiter: ImportConflictArbiter { _ in (.skip, true) })

        #expect(plan.groups.isEmpty)
        #expect(try #require(plan.sessions.first).groupID == nil)
    }
}
