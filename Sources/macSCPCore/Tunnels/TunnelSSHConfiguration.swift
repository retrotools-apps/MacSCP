import Foundation

/// Resolves a tunnel carrier and its optional saved bastion without opening
/// SFTP, modifying sessions, or persisting credentials in tunnel profiles.
public enum TunnelSSHConfiguration {
    public enum ResolutionError: Error, Sendable {
        case targetTLSBehindJump
        case metadataOnlyStore
    }

    /// Resolve references first, then read credentials with throwing access.
    /// The form-oriented LoginResolver intentionally tolerates failed reads;
    /// unattended tunnel dials must not mistake a denied read for no password.
    private struct MetadataOnlySecrets: SecretStore {
        func password(for sessionID: UUID) throws -> String? { nil }
        func savePassword(_ password: String, for sessionID: UUID) throws { throw ResolutionError.metadataOnlyStore }
        func deletePassword(for sessionID: UUID) throws { throw ResolutionError.metadataOnlyStore }
    }

    /// Configuration-only preflight for editors; never reads credentials.
    public static func validateRoute(profile: TunnelProfile, sessions: [StoredSession]) throws {
        guard let session = sessions.first(where: { $0.id == profile.sessionID }) else {
            throw TunnelRefusal.sessionMissing
        }
        guard session.kind == .ssh, let ssh = session.ssh else {
            throw TunnelRefusal.notSSH(session: session.name, connectionKind: session.kind)
        }
        let hopID = profile.jumpSessionID ?? ssh.jump?.sessionID
        if let hopID {
            guard let hop = sessions.first(where: { $0.id == hopID }) else { throw LoginResolveError.missingJumpSession }
            guard hop.kind == .ssh else { throw LoginResolveError.jumpSessionNotSSH }
            guard hop.id != session.id, hop.jump == nil else { throw LoginResolveError.jumpChainNotSupported }
        }
        if (profile.jumpSessionID != nil || ssh.jump != nil), ssh.tlsTunnel != nil {
            throw ResolutionError.targetTLSBehindJump
        }
    }

    public static func resolve(
        profile: TunnelProfile, sessions: [StoredSession], sets: [LoginSet],
        keys: ManagedKeyStore, secrets: any SecretStore
    ) throws -> SSHConnectionConfig {
        try validateRoute(profile: profile, sessions: sessions)
        guard let session = sessions.first(where: { $0.id == profile.sessionID }) else {
            throw TunnelRefusal.sessionMissing
        }
        guard session.kind == .ssh, let ssh = session.ssh else {
            throw TunnelRefusal.notSSH(session: session.name, connectionKind: session.kind)
        }
        var login: ResolvedLogin
        if let resolved = try LoginResolver.sshLogin(session: session, sets: sets, secrets: MetadataOnlySecrets()) {
            login = resolved
        } else {
            login = ResolvedLogin(
                username: ssh.username, authKind: ssh.authKind, keyPath: ssh.keyPath,
                secret: nil)
        }
        let spec = profile.jumpSessionID.map {
            StoredSession.JumpSpec(host: "", username: "", sessionID: $0)
        } ?? ssh.jump
        var jump: SSHConnectionConfig.Jump?
        if let spec {
            // The shared transport supports TLS on the first hop. Do not
            // silently bypass a TLS requirement on an inner SSH endpoint.
            guard ssh.tlsTunnel == nil else { throw ResolutionError.targetTLSBehindJump }
            var resolved = try LoginResolver.resolveJump(
                spec: spec, sets: sets, secrets: MetadataOnlySecrets(), sessions: sessions,
                referencingSessionID: session.id)
            if resolved.login.authKind != .agent {
                let slot = spec.sessionID.flatMap { id in sessions.first { $0.id == id }?.secretSlot }
                    ?? spec.loginSetID ?? spec.secretID
                resolved.login.secret = try secrets.password(for: slot)
            }
            jump = SSHConnectionConfig.Jump(
                host: resolved.host, port: resolved.port, username: resolved.login.username,
                auth: try authentication(resolved.login, keys: keys, secrets: secrets, isJump: true),
                tlsTunnel: resolved.tlsTunnel)
        }
        if login.authKind != .agent { login.secret = try secrets.password(for: session.secretSlot) }
        let auth = try authentication(login, keys: keys, secrets: secrets, isJump: false)
        return try SSHConnectionConfig(
            host: ssh.host, port: ssh.port, username: login.username, auth: auth,
            jump: jump, tlsTunnel: ssh.tlsTunnel)
    }

    private static func authentication(
        _ login: ResolvedLogin, keys: ManagedKeyStore, secrets: any SecretStore, isJump: Bool
    ) throws -> SSHConnectionConfig.AuthMethod {
        switch login.authKind {
        case .agent: return .agent
        case .password:
            guard let password = login.secret, !password.isEmpty else {
                throw StoredSessionConnectionError.secretRequired(checked: [.keychain])
            }
            return .password(password)
        case .privateKey:
            let path = login.keyPath ?? ""
            let passphrase: String?
            if isJump || login.secret?.isEmpty != false {
                let managed = ManagedKeyPassphraseSecretSource(keyPath: path, keys: keys, secrets: secrets)
                passphrase = try managed.secret(for: UUID()) ?? login.secret
            } else { passphrase = login.secret }
            return .privateKey(keyPath: path, passphrase: passphrase)
        }
    }
}
