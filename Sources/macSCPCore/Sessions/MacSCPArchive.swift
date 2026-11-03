import Foundation

/// Manifest stored inside every `.macscp` file. The envelope adds its own
/// top-level `encrypted` flag; these flags describe what the payload carries.
public struct MacSCPArchiveManifest: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case connection, group, loginSets, all }

    public var scope: Scope
    public var includesConnections: Bool
    public var includesLoginSets: Bool
    public var includesIdentities: Bool
    public var includesSecrets: Bool
    public var includesPrivateKeys: Bool
    public var includesTunnels: Bool

    public init(
        scope: Scope, includesConnections: Bool, includesLoginSets: Bool,
        includesIdentities: Bool, includesSecrets: Bool,
        includesPrivateKeys: Bool, includesTunnels: Bool
    ) {
        self.scope = scope
        self.includesConnections = includesConnections
        self.includesLoginSets = includesLoginSets
        self.includesIdentities = includesIdentities
        self.includesSecrets = includesSecrets
        self.includesPrivateKeys = includesPrivateKeys
        self.includesTunnels = includesTunnels
    }
}

/// The one public MacSCP interchange format. `connections` uses the same
/// mature model as the old session-only export, while the manifest and the
/// tunnel sections make the container self-describing and extensible.
public struct MacSCPArchivePayload: Codable, Equatable, Sendable {
    public var manifest: MacSCPArchiveManifest
    public var connections: SessionExportPayload?
    public var loginSets: LoginSetExportPayload?
    public var tunnelGroups: [TunnelGroup]
    public var tunnels: [TunnelProfile]

    public init(
        manifest: MacSCPArchiveManifest, connections: SessionExportPayload? = nil,
        loginSets: LoginSetExportPayload? = nil,
        tunnelGroups: [TunnelGroup] = [], tunnels: [TunnelProfile] = []
    ) {
        self.manifest = manifest
        self.connections = connections
        self.loginSets = loginSets
        self.tunnelGroups = tunnelGroups
        self.tunnels = tunnels
    }
}

public enum MacSCPArchiveCodec {
    public static let fileExtension = "macscp"
    private static let format = "macscp"
    private static let currentVersion = 1

    public static func encode(
        _ payload: MacSCPArchivePayload, password: String?
    ) throws -> Data {
        try validate(payload)
        return try ExportEnvelopeCodec.encode(
            payload, format: format, version: currentVersion, password: password)
    }
    public static func probe(_ data: Data) throws -> Bool {
        try ExportEnvelopeCodec.probe(
            data, as: MacSCPArchivePayload.self, format: format,
            currentVersion: currentVersion)
    }

    public static func decode(
        _ data: Data, password: String? = nil
    ) throws -> MacSCPArchivePayload {
        let payload = try ExportEnvelopeCodec.decode(
            data, as: MacSCPArchivePayload.self, format: format,
            currentVersion: currentVersion, password: password)
        try validate(payload)
        return payload
    }

    private static func validate(_ payload: MacSCPArchivePayload) throws {
        let hasConnections = payload.connections != nil
        let hasLoginSets = payload.loginSets != nil
        let hasTunnels = !payload.tunnels.isEmpty || !payload.tunnelGroups.isEmpty
        let hasSecrets = (payload.connections?.includesSecrets ?? false)
            || (payload.loginSets?.includesSecrets ?? false)
        let hasPrivateKeys = payload.loginSets?.includesKeyFiles ?? false
        guard hasConnections || hasLoginSets,
              payload.manifest.includesConnections == hasConnections,
              payload.manifest.includesLoginSets == hasLoginSets,
              payload.manifest.includesSecrets == hasSecrets,
              payload.manifest.includesPrivateKeys == hasPrivateKeys,
              payload.manifest.includesTunnels == hasTunnels else {
            throw SessionExportError.notAnExportFile
        }
        if hasLoginSets && !payload.manifest.includesIdentities {
            throw SessionExportError.notAnExportFile
        }
        if hasTunnels && !hasConnections {
            throw SessionExportError.notAnExportFile
        }
        if !payload.manifest.includesSecrets {
            guard payload.connections?.sessions.allSatisfy({
                $0.password == nil && $0.jumpPassword == nil && $0.s3SecretAccessKey == nil
            }) != false,
            payload.loginSets?.sets.allSatisfy({
                $0.secret == nil && ($0.embeddedKey?.passphrase ?? "").isEmpty
            }) != false else { throw SessionExportError.notAnExportFile }
        }
        if !payload.manifest.includesPrivateKeys,
           payload.loginSets?.sets.contains(where: { $0.embeddedKey != nil }) == true {
            throw SessionExportError.notAnExportFile
        }
    }
}

public enum MacSCPArchiveBuilder {
    public static func build(
        scope: MacSCPArchiveManifest.Scope,
        connections source: SessionExportPayload,
        includeIdentities: Bool,
        tunnels allTunnels: [TunnelProfile], tunnelGroups: [TunnelGroup]
    ) -> MacSCPArchivePayload {
        var connections = source
        if !includeIdentities {
            connections.includesSecrets = false
            connections.sessions = connections.sessions.map(redacted)
        }
        let sessionIDs = Set(connections.sessions.map(\.id))
        let tunnels = allTunnels.compactMap { profile -> TunnelProfile? in
            guard sessionIDs.contains(profile.sessionID) else { return nil }
            return TunnelProfile(
                id: profile.id, sessionID: profile.sessionID, name: profile.name,
                kind: profile.kind, autoStart: .off, reconnects: profile.reconnects,
                service: profile.service,
                jumpSessionID: profile.jumpSessionID.flatMap {
                    sessionIDs.contains($0) ? $0 : nil
                },
                groupID: profile.groupID, appearance: profile.appearance)
        }
        let includedTunnelGroups = referencedTunnelGroups(
            Set(tunnels.compactMap(\.groupID)), in: tunnelGroups)
        return MacSCPArchivePayload(
            manifest: MacSCPArchiveManifest(
                scope: scope, includesConnections: true, includesLoginSets: false,
                includesIdentities: includeIdentities,
                includesSecrets: connections.includesSecrets,
                includesPrivateKeys: false,
                includesTunnels: !tunnels.isEmpty),
            connections: connections,
            tunnelGroups: includedTunnelGroups,
            tunnels: tunnels)
    }

    public static func loginSets(_ payload: LoginSetExportPayload) -> MacSCPArchivePayload {
        MacSCPArchivePayload(
            manifest: MacSCPArchiveManifest(
                scope: .loginSets, includesConnections: false, includesLoginSets: true,
                includesIdentities: true, includesSecrets: payload.includesSecrets,
                includesPrivateKeys: payload.includesKeyFiles, includesTunnels: false),
            loginSets: payload)
    }

    public static func addingLoginSets(
        _ loginSets: LoginSetExportPayload, to archive: MacSCPArchivePayload
    ) -> MacSCPArchivePayload {
        var result = archive
        result.loginSets = loginSets
        result.manifest.scope = .all
        result.manifest.includesLoginSets = true
        result.manifest.includesIdentities = true
        result.manifest.includesSecrets = result.manifest.includesSecrets || loginSets.includesSecrets
        result.manifest.includesPrivateKeys = loginSets.includesKeyFiles
        return result
    }

    /// Defense in depth for both creation and import of anonymous shares.
    /// Connection addresses remain; login identities and every secret do not.
    public static func redacted(_ source: ExportedSession) -> ExportedSession {
        var session = source
        var values = FieldValues(raw: session.fields)
        values[SSHField.username] = ""
        values[SSHField.keyPath] = ""
        values[S3Field.accessKeyID] = ""
        values[S3Field.endpoint] = removingURLCredentials(from: values[S3Field.endpoint])
        values[WebDAVField.username] = ""
        values[WebDAVField.baseURL] = removingURLCredentials(from: values[WebDAVField.baseURL])
        session.fields = values.raw
        session.password = nil
        session.jumpUsername = session.jumpHost == nil ? nil : ""
        session.jumpKeyPath = nil
        session.jumpPassword = nil
        session.s3SecretAccessKey = nil
        session.importSource = nil
        session.importID = nil
        session.importedAt = nil
        return session
    }

    private static func removingURLCredentials(from raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.user != nil || components.password != nil else { return raw }
        components.user = nil
        components.password = nil
        return components.string ?? ""
    }

    private static func referencedTunnelGroups(
        _ referenced: Set<UUID>, in groups: [TunnelGroup]
    ) -> [TunnelGroup] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = referenced
        for id in referenced {
            var parent = byID[id]?.parentID
            var seen: Set<UUID> = []
            while let current = parent, seen.insert(current).inserted,
                  let group = byID[current] {
                included.insert(current)
                parent = group.parentID
            }
        }
        return groups.filter { included.contains($0.id) }
    }
}

public struct AnonymousConnectionImportPlan: Sendable {
    public var groups: [StoredGroup]
    public var sessions: [StoredSession]
    public var sessionIDMap: [UUID: UUID]
}

public struct MacSCPTunnelImportPlan: Sendable {
    public var groups: [TunnelGroup]
    public var tunnels: [TunnelProfile]
}

public enum MacSCPArchiveImportPlanner {
    /// Redacted sessions intentionally fail the ordinary importer's
    /// dialability check. They are stored as editable configurations with
    /// blank identity fields so the recipient can fill those locally.
    public static func anonymousConnections(
        from archive: MacSCPArchivePayload,
        existingSessions: [StoredSession], existingGroups: [StoredGroup]
    ) -> AnonymousConnectionImportPlan {
        guard let connections = archive.connections else {
            return AnonymousConnectionImportPlan(groups: [], sessions: [], sessionIDMap: [:])
        }
        let source = connections.sessions.map(MacSCPArchiveBuilder.redacted)
        let groupPlan = rekeyGroups(connections.groups, existing: existingGroups)
        let sessionIDMap = Dictionary(uniqueKeysWithValues: source.map { ($0.id, UUID()) })
        var takenNames = Set(existingSessions.map { normalized($0.name) })
        var sessions: [StoredSession] = []
        for item in source {
            let name = uniqueName(item.name, taken: &takenNames)
            let kind = item.kind ?? .ssh
            var stored = StoredSession(
                id: sessionIDMap[item.id] ?? UUID(), name: name,
                groupID: item.groupID.flatMap { groupPlan.map[$0] }, kind: kind,
                position: item.position ?? 0, appearance: item.appearance)
            if !item.fields.isEmpty {
                BackendDescriptor.descriptor(for: kind).apply(
                    FieldValues(raw: item.fields), &stored)
            }
            if let host = item.jumpHost {
                stored.ssh?.jump = StoredSession.JumpSpec(
                    host: host, port: item.jumpPort ?? 22, username: "",
                    authKind: item.jumpAuthKind ?? .password,
                    tlsTunnel: item.jumpTLSTunnel)
            }
            sessions.append(stored)
        }
        return AnonymousConnectionImportPlan(
            groups: groupPlan.groups, sessions: sessions, sessionIDMap: sessionIDMap)
    }

    public static func tunnels(
        from archive: MacSCPArchivePayload, sessionIDMap: [UUID: UUID],
        existingGroups: [TunnelGroup]
    ) -> MacSCPTunnelImportPlan {
        guard archive.manifest.includesTunnels else {
            return MacSCPTunnelImportPlan(groups: [], tunnels: [])
        }
        let groupPlan = rekeyTunnelGroups(archive.tunnelGroups, existing: existingGroups)
        let tunnels = archive.tunnels.compactMap { source -> TunnelProfile? in
            guard let sessionID = sessionIDMap[source.sessionID] else { return nil }
            return TunnelProfile(
                sessionID: sessionID, name: source.name, kind: source.kind,
                autoStart: .off, reconnects: source.reconnects, service: source.service,
                jumpSessionID: source.jumpSessionID.flatMap { sessionIDMap[$0] },
                groupID: source.groupID.flatMap { groupPlan.map[$0] },
                appearance: source.appearance)
        }
        return MacSCPTunnelImportPlan(groups: groupPlan.groups, tunnels: tunnels)
    }

    private static func rekeyGroups(
        _ source: [ExportedGroup], existing: [StoredGroup]
    ) -> (groups: [StoredGroup], map: [UUID: UUID]) {
        var pending = source
        var result: [StoredGroup] = []
        var map: [UUID: UUID] = [:]
        var occupied = existing.map { ($0.parentID, normalized($0.name)) }
        while !pending.isEmpty {
            var progressed = false
            for index in pending.indices.reversed() {
                let group = pending[index]
                guard group.parentID == nil || map[group.parentID!] != nil else { continue }
                let parent = group.parentID.flatMap { map[$0] }
                let name = uniqueGroupName(group.name, parent: parent, occupied: &occupied)
                let id = UUID()
                map[group.id] = id
                result.append(StoredGroup(
                    id: id, name: name, parentID: parent, position: group.position ?? 0,
                    colorHue: group.colorHue, color: group.color))
                pending.remove(at: index)
                progressed = true
            }
            if !progressed {
                let group = pending.removeFirst()
                let name = uniqueGroupName(group.name, parent: nil, occupied: &occupied)
                let id = UUID()
                map[group.id] = id
                result.append(StoredGroup(
                    id: id, name: name, position: group.position ?? 0,
                    colorHue: group.colorHue, color: group.color))
            }
        }
        return (result, map)
    }

    private static func rekeyTunnelGroups(
        _ source: [TunnelGroup], existing: [TunnelGroup]
    ) -> (groups: [TunnelGroup], map: [UUID: UUID]) {
        var pending = source
        var result: [TunnelGroup] = []
        var map: [UUID: UUID] = [:]
        var occupied = existing.map { ($0.parentID, normalized($0.name)) }
        while !pending.isEmpty {
            var progressed = false
            for index in pending.indices.reversed() {
                let group = pending[index]
                guard group.parentID == nil || map[group.parentID!] != nil else { continue }
                let parent = group.parentID.flatMap { map[$0] }
                let name = uniqueGroupName(group.name, parent: parent, occupied: &occupied)
                let id = UUID()
                map[group.id] = id
                result.append(TunnelGroup(
                    id: id, name: name, parentID: parent,
                    colorHue: group.colorHue, color: group.color))
                pending.remove(at: index)
                progressed = true
            }
            if !progressed {
                let group = pending.removeFirst()
                let name = uniqueGroupName(group.name, parent: nil, occupied: &occupied)
                let id = UUID()
                map[group.id] = id
                result.append(TunnelGroup(
                    id: id, name: name, colorHue: group.colorHue, color: group.color))
            }
        }
        return (result, map)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func uniqueName(_ requested: String, taken: inout Set<String>) -> String {
        let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = base.isEmpty ? "Imported configuration" : base
        var candidate = usable
        var suffix = 2
        while !taken.insert(normalized(candidate)).inserted {
            candidate = "\(usable) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private static func uniqueGroupName(
        _ requested: String, parent: UUID?, occupied: inout [(UUID?, String)]
    ) -> String {
        let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = base.isEmpty ? "Imported group" : base
        var candidate = usable
        var suffix = 2
        while occupied.contains(where: { $0.0 == parent && $0.1 == normalized(candidate) }) {
            candidate = "\(usable) (\(suffix))"
            suffix += 1
        }
        occupied.append((parent, normalized(candidate)))
        return candidate
    }
}
