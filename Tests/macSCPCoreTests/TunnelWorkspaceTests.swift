import Foundation
import Testing
@testable import macSCPCore

@Suite("Independent tunnel configuration")
struct TunnelWorkspaceTests {
    private struct Secrets: SecretStore {
        let entries: [UUID: String]
        func password(for slot: UUID) throws -> String? { entries[slot] }
        func savePassword(_ password: String, for slot: UUID) throws {}
        func deletePassword(for slot: UUID) throws {}
    }

    private struct UnreadableSecrets: SecretStore {
        struct Refused: Error {}
        func password(for slot: UUID) throws -> String? { throw Refused() }
        func savePassword(_ password: String, for slot: UUID) throws { throw Refused() }
        func deletePassword(for slot: UUID) throws { throw Refused() }
    }

    private func mapping(session: UUID = UUID(), port: Int = 19080, bind: String = "127.0.0.1") -> TunnelProfile {
        TunnelProfile(sessionID: session, name: "Web", kind: .local(
            bind: bind, localPort: port, host: "service.example", remotePort: 80))
    }

    @Test func oldProfilesDecodeAndNewMetadataRoundtrips() throws {
        let old = mapping()
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("jumpSessionID"))
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: data)
        #expect(decoded.service == nil)
        #expect(decoded.jumpSessionID == nil)
        var updated = decoded
        updated.service = .https
        updated.jumpSessionID = UUID()
        #expect(try JSONDecoder().decode(TunnelProfile.self, from: JSONEncoder().encode(updated)) == updated)
    }

    @Test func localAndSocksListenersConflictAcrossDifferentCarriers() {
        let first = mapping()
        var second = mapping()
        second.kind = .dynamic(bind: "localhost", localPort: 19080)
        #expect(TunnelEndpoints.conflict(for: second, among: [first])?.id == first.id)
        #expect(TunnelEndpoints.conflict(for: first, among: [first]) == nil)
        second.kind = .dynamic(bind: "127.0.0.1", localPort: 19081)
        #expect(TunnelEndpoints.conflict(for: second, among: [first]) == nil)
    }

    @Test func wildcardOverlapsSpecificAddressesButDisjointAddressesDoNot() {
        let first = mapping(bind: "0.0.0.0")
        #expect(TunnelEndpoints.conflict(for: mapping(bind: "192.0.2.10"), among: [first]) != nil)
        #expect(TunnelEndpoints.conflict(for: mapping(bind: "192.0.2.10"), among: [mapping()]) == nil)
    }

    @Test func remoteListenerScopeIsTheCarrierNotThisMac() {
        let first = mapping()
        var remote = mapping(session: first.sessionID)
        remote.kind = .remote(bind: "127.0.0.1", remotePort: 19080, localHost: "localhost", localPort: 80)
        #expect(TunnelEndpoints.conflict(for: remote, among: [first]) == nil)
        var sameServer = remote
        sameServer = TunnelProfile(sessionID: remote.sessionID, name: "Other", kind: remote.kind)
        #expect(TunnelEndpoints.conflict(for: sameServer, among: [remote]) != nil)
        sameServer.sessionID = UUID()
        #expect(TunnelEndpoints.conflict(for: sameServer, among: [remote]) == nil)
    }

    @Test func browserURLsRequireLocalHTTPAndUseLoopbackForWildcard() throws {
        var profile = mapping(bind: "0.0.0.0")
        #expect(TunnelEndpoints.browserURL(for: profile) == nil)
        profile.service = .https
        #expect(TunnelEndpoints.browserURL(for: profile)?.absoluteString == "https://127.0.0.1:19080/")
        profile.kind = .local(bind: "::1", localPort: 19080, host: "service.example", remotePort: 80)
        #expect(TunnelEndpoints.browserURL(for: profile)?.absoluteString == "https://[::1]:19080/")
        profile.kind = .dynamic(bind: "127.0.0.1", localPort: 19080)
        #expect(TunnelEndpoints.browserURL(for: profile) == nil)
        profile.kind = .remote(bind: "127.0.0.1", remotePort: 19080, localHost: "localhost", localPort: 80)
        #expect(TunnelEndpoints.browserURL(for: profile) == nil)
    }

    @Test func savedJumpRetainsTLSAndUsesItsOwnLoginSet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let set = LoginSet(name: "Gateway account", username: "gateway-user")
        var gatewaySSH = StoredSSHConfig(host: "gateway.example", username: "ignored")
        gatewaySSH.tlsTunnel = try SSHTLSTunnelConfig(host: "tls.example", serverName: "ssh.example")
        let gateway = StoredSession(name: "Gateway", loginSetID: set.id, ssh: gatewaySSH)
        let target = StoredSession(name: "Service", ssh: .init(host: "service.example", username: "target-user"))
        var profile = mapping(session: target.id)
        profile.jumpSessionID = gateway.id
        let targetSecret = "target-fixture-only", gatewaySecret = "gateway-fixture-only"
        let config = try TunnelSSHConfiguration.resolve(
            profile: profile, sessions: [target, gateway], sets: [set],
            keys: ManagedKeyStore(directory: directory),
            secrets: Secrets(entries: [target.id: targetSecret, set.id: gatewaySecret]))
        #expect(config.host == "service.example")
        #expect(config.username == "target-user")
        #expect(config.jump?.username == "gateway-user")
        #expect(config.jump?.tlsTunnel == gatewaySSH.tlsTunnel)
        #expect(config.jump?.tlsTunnel?.verifyCertificate == true)
        let correctTarget = config.auth == .password(targetSecret)
        let correctJump = config.jump?.auth == .password(gatewaySecret)
        #expect(correctTarget)
        #expect(correctJump)
        #expect(target.jump == nil)
    }

    @Test func inheritedJumpAndAgentLoginsNeverReadSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gateway = StoredSession(name: "Gateway", ssh: .init(host: "gateway.example", username: "hop", authKind: .agent))
        let target = StoredSession(name: "Service", ssh: .init(
            host: "service.example", username: "operator", authKind: .agent,
            jump: .init(host: "", username: "", sessionID: gateway.id)))
        let config = try TunnelSSHConfiguration.resolve(
            profile: mapping(session: target.id), sessions: [target, gateway], sets: [],
            keys: ManagedKeyStore(directory: directory), secrets: UnreadableSecrets())
        let targetAgent = config.auth == .agent, jumpAgent = config.jump?.auth == .agent
        #expect(targetAgent)
        #expect(jumpAgent)
    }

    @Test func missingPasswordIsNotSentAsAnEmptyCredential() throws {
        let session = StoredSession(name: "Service", ssh: .init(host: "service.example", username: "operator"))
        #expect(throws: StoredSessionConnectionError.secretRequired(checked: [.keychain])) {
            try TunnelSSHConfiguration.resolve(
                profile: mapping(session: session.id), sessions: [session], sets: [],
                keys: ManagedKeyStore(directory: .temporaryDirectory), secrets: Secrets(entries: [:]))
        }
    }

    @Test func deniedCredentialReadsAreNotReportedAsAnAbsentPassword() throws {
        let set = LoginSet(name: "Account", username: "operator")
        let session = StoredSession(name: "Service", loginSetID: set.id,
                                    ssh: .init(host: "service.example", username: "ignored"))
        #expect(throws: UnreadableSecrets.Refused.self) {
            try TunnelSSHConfiguration.resolve(profile: mapping(session: session.id), sessions: [session], sets: [set],
                keys: ManagedKeyStore(directory: .temporaryDirectory), secrets: UnreadableSecrets())
        }
    }

    @Test func nestedTLSAndChainedJumpsAreRejectedBeforeReadingCredentials() throws {
        var ssh = StoredSSHConfig(host: "inner.example", username: "operator")
        ssh.tlsTunnel = try SSHTLSTunnelConfig(host: "tls.example")
        let target = StoredSession(name: "Service", ssh: ssh)
        let hop = StoredSession(name: "Gateway", ssh: .init(host: "gateway.example", username: "operator"))
        var profile = mapping(session: target.id)
        profile.jumpSessionID = hop.id
        #expect(throws: TunnelSSHConfiguration.ResolutionError.self) {
            try TunnelSSHConfiguration.resolve(profile: profile, sessions: [target, hop], sets: [],
                keys: ManagedKeyStore(directory: .temporaryDirectory), secrets: UnreadableSecrets())
        }
        var chained = hop
        chained.ssh?.jump = .init(host: "another.example", username: "operator")
        #expect(throws: LoginResolveError.jumpChainNotSupported) {
            try TunnelSSHConfiguration.validateRoute(profile: profile, sessions: [target, chained])
        }
    }

    @Test func missingJumpAndSelfReferenceFailClosed() throws {
        let session = StoredSession(name: "Service", ssh: .init(host: "service.example", username: "operator", authKind: .agent))
        var profile = mapping(session: session.id)
        profile.jumpSessionID = UUID()
        #expect(throws: LoginResolveError.missingJumpSession) {
            try TunnelSSHConfiguration.resolve(profile: profile, sessions: [session], sets: [],
                keys: ManagedKeyStore(directory: .temporaryDirectory), secrets: UnreadableSecrets())
        }
        profile.jumpSessionID = session.id
        #expect(throws: LoginResolveError.jumpChainNotSupported) {
            try TunnelSSHConfiguration.resolve(profile: profile, sessions: [session], sets: [],
                keys: ManagedKeyStore(directory: .temporaryDirectory), secrets: UnreadableSecrets())
        }
    }
}
