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
    private static let currentVersion = 2

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
        let sourceSessionIDs = Set(connections.sessions.map(\.id))
        for index in connections.groups.indices {
            if !includeIdentities { connections.groups[index].loginSetID = nil }
            if connections.groups[index].sshRelaySessionID.map(sourceSessionIDs.contains) != true {
                connections.groups[index].sshRelaySessionID = nil
            }
        }
        if !includeIdentities {
            connections.includesSecrets = false
            connections.sessions = connections.sessions.map(redacted)
        }
        let sessionIDs = Set(connections.sessions.map(\.id))
        let tunnels = allTunnels.compactMap { profile -> TunnelProfile? in
            guard sessionIDs.contains(profile.sessionID) else { return nil }
            return TunnelProfile(
                id: profile.id, sessionID: profile.sessionID, name: profile.name,
                kind: profile.kind, autoStart: profile.autoStart, reconnects: profile.reconnects,
                service: profile.service,
                jumpSessionID: profile.jumpSessionID.flatMap {
                    sessionIDs.contains($0) ? $0 : nil
                },
                groupID: profile.groupID, appearance: profile.appearance,
                portableID: profile.portableID ?? profile.id)
        }
        let selectedTunnelGroups = scope == .all
            ? tunnelGroups
            : referencedTunnelGroups(Set(tunnels.compactMap(\.groupID)), in: tunnelGroups)
        let includedTunnelGroups = selectedTunnelGroups.map { group in
                TunnelGroup(
                    id: group.id, name: group.name, parentID: group.parentID,
                    colorHue: group.colorHue, color: group.color,
                    portableID: group.portableID ?? group.id)
            }
        return MacSCPArchivePayload(
            manifest: MacSCPArchiveManifest(
                scope: scope, includesConnections: true, includesLoginSets: false,
                includesIdentities: includeIdentities,
                includesSecrets: connections.includesSecrets,
                includesPrivateKeys: false,
                includesTunnels: !tunnels.isEmpty || !includedTunnelGroups.isEmpty),
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
        session.loginSetID = nil
        session.jumpLoginSetID = nil
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
    public var skipped: [String] = []
    public var replaced: [String] = []
    public var renamed: [String] = []
    public var cancelled = false
}

public struct MacSCPTunnelImportPlan: Sendable {
    public var groups: [TunnelGroup]
    public var tunnels: [TunnelProfile]
    public var skipped: [String]
    public var replaced: [String]
    public var renamed: [String]
    public var cancelled: Bool

    public init(
        groups: [TunnelGroup] = [], tunnels: [TunnelProfile] = [],
        skipped: [String] = [], replaced: [String] = [], renamed: [String] = [],
        cancelled: Bool = false
    ) {
        self.groups = groups
        self.tunnels = tunnels
        self.skipped = skipped
        self.replaced = replaced
        self.renamed = renamed
        self.cancelled = cancelled
    }
}

public enum MacSCPArchiveImportPlanner {
    public static let anonymousSessionKindLabel = "anonymousSession"
    public static let tunnelGroupKindLabel = "tunnelGroup"
    public static let tunnelKindLabel = "tunnel"
    /// Redacted sessions intentionally fail the ordinary importer's
    /// dialability check. They are stored as editable configurations with
    /// blank identity fields so the recipient can fill those locally.
    public static func anonymousConnections(
        from archive: MacSCPArchivePayload,
        existingSessions: [StoredSession], existingGroups: [StoredGroup],
        arbiter: ImportConflictArbiter
    ) async -> AnonymousConnectionImportPlan {
        guard let connections = archive.connections else {
            return AnonymousConnectionImportPlan(groups: [], sessions: [], sessionIDMap: [:])
        }
        let source = connections.sessions.map(MacSCPArchiveBuilder.redacted)
        var groupMap: [UUID: UUID] = [:]
        var groups: [StoredGroup] = []
        var pendingGroups = connections.groups
        while !pendingGroups.isEmpty {
            guard let index = pendingGroups.firstIndex(where: {
                $0.parentID == nil || groupMap[$0.parentID!] != nil
            }) else { break }
            let item = pendingGroups.remove(at: index)
            let parentID = item.parentID.flatMap { groupMap[$0] }
            let portableID = item.portableID ?? item.id
            let match = existingGroups.first { $0.portableID == portableID }
                ?? existingGroups.first {
                    $0.parentID == parentID && normalized($0.name) == normalized(item.name)
                }
            if let match {
                guard let resolution = await arbiter.resolve(ImportConflict(
                    itemName: item.name, kindLabel: SessionImportPlanner.groupKindLabel,
                    reason: .name)) else {
                    return AnonymousConnectionImportPlan(
                        groups: [], sessions: [], sessionIDMap: [:], cancelled: true)
                }
                switch resolution {
                case .skip:
                    groupMap[item.id] = match.id
                case .replace:
                    let replacement = StoredGroup(
                        id: match.id, name: item.name, parentID: parentID,
                        position: item.position ?? 0, colorHue: item.colorHue,
                        color: item.color, portableID: portableID,
                        sshRelaySessionID: item.sshRelaySessionID)
                    groups.append(replacement)
                    groupMap[item.id] = replacement.id
                case .rename:
                    var occupied = (existingGroups + groups).map {
                        ($0.parentID, normalized($0.name))
                    }
                    let name = uniqueGroupName(item.name, parent: parentID, occupied: &occupied)
                    let created = StoredGroup(
                        name: name, parentID: parentID, position: item.position ?? 0,
                        colorHue: item.colorHue, color: item.color,
                        portableID: portableID, sshRelaySessionID: item.sshRelaySessionID)
                    groups.append(created)
                    groupMap[item.id] = created.id
                }
            } else {
                let created = StoredGroup(
                    name: item.name, parentID: parentID, position: item.position ?? 0,
                    colorHue: item.colorHue, color: item.color,
                    portableID: portableID, sshRelaySessionID: item.sshRelaySessionID)
                groups.append(created)
                groupMap[item.id] = created.id
            }
        }
        var sessionIDMap: [UUID: UUID] = [:]
        var takenNames = Set(existingSessions.map { normalized($0.name) })
        var sessions: [StoredSession] = []
        var skipped: [String] = []
        var replaced: [String] = []
        var renamed: [String] = []
        var claimedExisting: Set<UUID> = []
        var prospectiveGroups = existingGroups
        for group in groups {
            if let index = prospectiveGroups.firstIndex(where: { $0.id == group.id }) {
                prospectiveGroups[index] = group
            } else {
                prospectiveGroups.append(group)
            }
        }
        let importedGroupIDs = Set(groups.map(\.id))
        for item in source {
            let kind = item.kind ?? .ssh
            let portableID = item.portableID ?? item.id
            let match = existingSessions.first {
                $0.portableID == portableID && !claimedExisting.contains($0.id)
            } ?? existingSessions.first {
                $0.kind == kind && normalized($0.name) == normalized(item.name)
                    && !claimedExisting.contains($0.id)
            }
            var id = UUID()
            var name = item.name
            if let match {
                guard let resolution = await arbiter.resolve(ImportConflict(
                    itemName: item.name, kindLabel: anonymousSessionKindLabel,
                    reason: .name)) else {
                    return AnonymousConnectionImportPlan(
                        groups: [], sessions: [], sessionIDMap: [:], cancelled: true)
                }
                switch resolution {
                case .skip:
                    sessionIDMap[item.id] = match.id
                    skipped.append(item.name)
                    continue
                case .replace:
                    id = match.id
                    claimedExisting.insert(match.id)
                    replaced.append(item.name)
                case .rename:
                    name = uniqueName(item.name, taken: &takenNames)
                    renamed.append(name)
                }
            } else {
                name = uniqueName(item.name, taken: &takenNames)
            }
            sessionIDMap[item.id] = id
            var stored = StoredSession(
                id: id, name: name, groupID: item.groupID.flatMap { groupMap[$0] }, kind: kind,
                position: item.position ?? 0, portableID: portableID,
                appearance: item.appearance)
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
            if inheritsLocalGroupDefault(
                stored, groups: prospectiveGroups, importedGroupIDs: importedGroupIDs) {
                // Anonymous shares carry no credential. Keeping this group
                // assignment would silently attach a local login set or SSH
                // relay from a group the user chose to keep local.
                stored.groupID = nil
            }
            sessions.append(stored)
        }
        for index in groups.indices {
            groups[index].sshRelaySessionID = groups[index].sshRelaySessionID
                .flatMap { sessionIDMap[$0] }
        }
        return AnonymousConnectionImportPlan(
            groups: groups, sessions: sessions, sessionIDMap: sessionIDMap,
            skipped: skipped, replaced: replaced, renamed: renamed)
    }

    public static func tunnels(
        from archive: MacSCPArchivePayload, sessionIDMap: [UUID: UUID],
        existingGroups: [TunnelGroup], existingTunnels: [TunnelProfile],
        arbiter: ImportConflictArbiter
    ) async -> MacSCPTunnelImportPlan {
        guard archive.manifest.includesTunnels else {
            return MacSCPTunnelImportPlan(groups: [], tunnels: [])
        }
        var groupMap: [UUID: UUID] = [:]
        var plannedGroups: [TunnelGroup] = []
        var pendingGroups = archive.tunnelGroups
        while !pendingGroups.isEmpty {
            guard let index = pendingGroups.firstIndex(where: {
                $0.parentID == nil || groupMap[$0.parentID!] != nil
            }) else { break }
            let source = pendingGroups.remove(at: index)
            let parentID = source.parentID.flatMap { groupMap[$0] }
            let portableID = source.portableID ?? source.id
            let match = existingGroups.first(where: { $0.portableID == portableID })
                ?? existingGroups.first(where: {
                    $0.parentID == parentID && normalized($0.name) == normalized(source.name)
                })
            if let match {
                guard let resolution = await arbiter.resolve(ImportConflict(
                    itemName: source.name, kindLabel: tunnelGroupKindLabel, reason: .name))
                else { return MacSCPTunnelImportPlan(cancelled: true) }
                switch resolution {
                case .skip:
                    groupMap[source.id] = match.id
                case .replace:
                    let replacement = TunnelGroup(
                        id: match.id, name: source.name, parentID: parentID,
                        colorHue: source.colorHue, color: source.color, portableID: portableID)
                    plannedGroups.append(replacement)
                    groupMap[source.id] = replacement.id
                case .rename:
                    var occupied = (existingGroups + plannedGroups).map {
                        ($0.parentID, normalized($0.name))
                    }
                    let name = uniqueGroupName(source.name, parent: parentID, occupied: &occupied)
                    let created = TunnelGroup(
                        name: name, parentID: parentID, colorHue: source.colorHue,
                        color: source.color, portableID: portableID)
                    plannedGroups.append(created)
                    groupMap[source.id] = created.id
                }
            } else {
                let created = TunnelGroup(
                    name: source.name, parentID: parentID, colorHue: source.colorHue,
                    color: source.color, portableID: portableID)
                plannedGroups.append(created)
                groupMap[source.id] = created.id
            }
        }

        var plannedTunnels: [TunnelProfile] = []
        var skipped: [String] = []
        var replaced: [String] = []
        var renamed: [String] = []
        var claimedExistingIDs: Set<UUID> = []
        for source in archive.tunnels {
            guard let sessionID = sessionIDMap[source.sessionID] else { continue }
            let groupID = source.groupID.flatMap { groupMap[$0] }
            let portableID = source.portableID ?? source.id
            let match = existingTunnels.first(where: {
                $0.portableID == portableID && !claimedExistingIDs.contains($0.id)
            }) ?? existingTunnels.first(where: {
                $0.groupID == groupID && normalized($0.name) == normalized(source.name)
                    && !claimedExistingIDs.contains($0.id)
            })
            var id = UUID()
            var name = source.name
            if let match {
                guard let resolution = await arbiter.resolve(ImportConflict(
                    itemName: source.name, kindLabel: tunnelKindLabel, reason: .name))
                else { return MacSCPTunnelImportPlan(cancelled: true) }
                switch resolution {
                case .skip:
                    skipped.append(source.name)
                    continue
                case .replace:
                    id = match.id
                    claimedExistingIDs.insert(match.id)
                    replaced.append(source.name)
                case .rename:
                    var suffix = 2
                    let base = source.name
                    let names = Set((existingTunnels + plannedTunnels).map { normalized($0.name) })
                    while names.contains(normalized(name)) {
                        name = "\(base) (\(suffix))"
                        suffix += 1
                    }
                    renamed.append(name)
                }
            }
            plannedTunnels.append(TunnelProfile(
                id: id, sessionID: sessionID, name: name, kind: source.kind,
                autoStart: source.autoStart, reconnects: source.reconnects, service: source.service,
                jumpSessionID: source.jumpSessionID.flatMap { sessionIDMap[$0] },
                groupID: groupID, appearance: source.appearance, portableID: portableID))
        }
        return MacSCPTunnelImportPlan(
            groups: plannedGroups, tunnels: plannedTunnels, skipped: skipped,
            replaced: replaced, renamed: renamed)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func inheritsLocalGroupDefault(
        _ session: StoredSession, groups: [StoredGroup], importedGroupIDs: Set<UUID>
    ) -> Bool {
        let byID = Dictionary(
            groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var needsLogin = session.loginSetID == nil
        var needsRelay = session.kind == .ssh && session.jump == nil
        var cursor = session.groupID
        var visited: Set<UUID> = []
        while let id = cursor, visited.insert(id).inserted, let group = byID[id] {
            if needsLogin, group.loginSetID != nil {
                if !importedGroupIDs.contains(id) { return true }
                needsLogin = false
            }
            if needsRelay, group.sshRelaySessionID != nil {
                if !importedGroupIDs.contains(id) { return true }
                needsRelay = false
            }
            if !needsLogin, !needsRelay { return false }
            cursor = group.parentID
        }
        return false
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
