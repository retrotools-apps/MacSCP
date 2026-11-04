import Foundation

/// Resolves independently inherited group defaults. A session-level value
/// always wins; otherwise the nearest ancestor defining that particular
/// value wins. Credential and relay defaults may therefore come from
/// different levels of the same group path.
public enum GroupSessionDefaults {
    public struct Resolution: Equatable, Sendable {
        public var loginSetID: UUID?
        public var sshRelaySessionID: UUID?
    }

    public static func resolve(
        for session: StoredSession, groups: [StoredGroup]
    ) -> Resolution {
        var loginSetID = session.loginSetID
        var relayID = session.jump == nil ? nil : session.jump?.sessionID
        let inheritsRelay = session.kind == .ssh && session.jump == nil
        let byID = Dictionary(
            groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cursor = session.groupID
        var visited: Set<UUID> = []
        while let id = cursor, visited.insert(id).inserted, let group = byID[id] {
            if loginSetID == nil { loginSetID = group.loginSetID }
            if inheritsRelay, relayID == nil,
               group.sshRelaySessionID != session.id {
                relayID = group.sshRelaySessionID
            }
            if loginSetID != nil, relayID != nil || !inheritsRelay { break }
            cursor = group.parentID
        }
        return Resolution(loginSetID: loginSetID, sshRelaySessionID: relayID)
    }

    public static func applying(
        to session: StoredSession, groups: [StoredGroup]
    ) -> StoredSession {
        let resolution = resolve(for: session, groups: groups)
        var effective = session
        if effective.loginSetID == nil { effective.loginSetID = resolution.loginSetID }
        if effective.kind == .ssh, effective.jump == nil,
           let relayID = resolution.sshRelaySessionID {
            effective.ssh?.jump = StoredSession.JumpSpec(
                host: "", username: "", sessionID: relayID)
        }
        return effective
    }
}
