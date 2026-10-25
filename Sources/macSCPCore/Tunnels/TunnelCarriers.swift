import Foundation

/// SSH capability shared by forwarding controls and the unresolved direct
/// connection API. The GUI resolves login sets and jumps before dialling;
/// only the compatibility API needs the additional unresolved-session refusals.
public enum TunnelCarriers {
    /// Whether a forwarding can be carried over a connection of this kind.
    ///
    /// Exhaustive on purpose — no `default`. There is no `direct-tcpip` over
    /// S3 or WebDAV, and a fourth backend must answer this question here
    /// rather than inherit `false` from a wildcard nobody revisits.
    public static func carries(_ kind: ConnectionKind) -> Bool {
        switch kind {
        case .ssh: return true
        case .s3, .webdav: return false
        }
    }

    /// Why the direct, session-only API cannot resolve this record. These
    /// refusals do not apply to `TunnelSSHConfiguration`'s complete GUI path.
    ///
    /// The three rules, and the order they are asked in, are
    /// `TunnelConnection.connect`'s — which throws exactly this refusal
    /// rather than deciding the same rules a second time. The order is the
    /// one `StoredSessionConnectionConfig.build` enforces (login set, then
    /// jump), with the protocol rule last because it is the one `build` does
    /// not answer; a session can trip more than one, and the refusal must
    /// name the rule the dial would actually stop at.
    ///
    /// Contains no secret: a session's name, its protocol, and the fact that
    /// it has a login set or a jump host. Not the jump's host name, not a
    /// login set's contents.
    public static func refusalError(for session: StoredSession) -> TunnelRefusal? {
        if session.loginSetID != nil {
            return .loginSet(session: session.name)
        }
        if session.jump != nil {
            return .jumpHost(session: session.name)
        }
        guard carries(session.kind) else {
            return .notSSH(session: session.name, connectionKind: session.kind)
        }
        return nil
    }

    /// The same refusal as its English sentence — `DialSupport.reason(for:)`
    /// of it, which is what the diagnostic log writes when the dial throws
    /// it, so the command line's refusal before anything is written and the
    /// log line of a failed dial cannot word the same rule differently.
    public static func refusal(for session: StoredSession) -> String? {
        refusalError(for: session).map { DialSupport.reason(for: $0) }
    }
}
