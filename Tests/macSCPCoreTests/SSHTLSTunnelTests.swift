import Foundation
import NIOSSL
import Testing
@testable import macSCPCore

@Suite("SSH over TLS configuration")
struct SSHTLSTunnelTests {
    @Test func tlsFailuresHaveAnActionableDescriptionInsteadOfANumericNSError() {
        let description = SSHTLSTransport.failureDescription(for: NIOSSLError.unableToValidateCertificate)
        #expect(description == CoreL10n.string("core.connect.tlsNegotiationFailed"))
        #expect(SSHTLSTransport.failureDescription(for: CancellationError()) == nil)
        let mapped = CitadelFileSystem.mapConnectError(NIOSSLError.unableToValidateCertificate)
        #expect(mapped as? RemoteFSError == .connectionFailed(reason: CoreL10n.string("core.connect.tlsNegotiationFailed")))
    }

    @Test func verificationIsEnabledByDefaultIncludingLegacyJSON() throws {
        let tunnel = try SSHTLSTunnelConfig(host: "gateway.example.com")
        #expect(tunnel.port == 443)
        #expect(tunnel.serverName == tunnel.host)
        #expect(tunnel.verifyCertificate)
        let old = Data(#"{"host":"gateway.example.com","port":443}"#.utf8)
        #expect(try JSONDecoder().decode(SSHTLSTunnelConfig.self, from: old).verifyCertificate)
        #expect(SSHTLSTransport.configuration().certificateVerification == .fullVerification)
        #expect(SSHTLSTransport.configuration(verifyCertificate: false).certificateVerification == .none)
    }

    @Test(arguments: [true, false])
    func schemaStorageAndRuntimeAgreeOnTLSVerification(verify: Bool) throws {
        var fields = SSHFieldSchema.defaults
        fields[SSHField.host] = "target.example.com"
        fields[SSHField.username] = "user"
        fields[SSHField.tlsHost] = "gateway.example.com"
        fields[bool: SSHField.tlsEnabled] = true
        fields[SSHField.tlsServerName] = "tls.example.com"
        fields[bool: SSHField.tlsVerify] = verify
        var stored = StoredSession(name: "TLS", kind: .ssh,
                                   ssh: StoredSSHConfig(host: "target.example.com", username: "user"))
        SSHFieldSchema.apply(fields, to: &stored)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
        let restored = SSHFieldSchema.values(from: decoded)
        let config = try SSHFieldSchema.makeConfig(restored, "fixture")
        guard case .ssh(let ssh) = config else { Issue.record("Wrong backend"); return }
        #expect(ssh.host == "target.example.com")
        #expect(ssh.tlsTunnel?.host == "gateway.example.com")
        #expect(ssh.tlsTunnel?.serverName == "tls.example.com")
        #expect(ssh.tlsTunnel?.verifyCertificate == verify)
        #expect(ssh.redactingSecrets().tlsTunnel == ssh.tlsTunnel)
    }

    @Test func freshFormDefaultsToVerification() {
        #expect(SSHFieldSchema.defaults[bool: SSHField.tlsVerify])
    }

    @Test func invalidGatewayAndProxyCommandInjectionAreRejected() {
        for host in ["", "-bad", "host;id", "host%h", "a b", "host\n", "$(id)"] {
            #expect(throws: (any Error).self) { try SSHTLSTunnelConfig(host: host) }
        }
        #expect(throws: (any Error).self) { try SSHTLSTunnelConfig(host: "gateway", port: 0) }
        #expect(throws: (any Error).self) {
            try SSHTLSTunnelConfig(host: "gateway", serverName: "host;id")
        }
    }

    @Test func invalidStoredValuesCannotSilentlyDisableTLS() throws {
        var fields = SSHFieldSchema.defaults
        fields[SSHField.host] = "target.example.com"
        fields[SSHField.username] = "user"
        fields[SSHField.tlsHost] = "bad;gateway"
        fields[bool: SSHField.tlsEnabled] = true
        var stored = StoredSession(name: "invalid", kind: .ssh,
                                   ssh: StoredSSHConfig(host: "target.example.com", username: "user"))
        SSHFieldSchema.apply(fields, to: &stored)
        #expect(stored.ssh?.tlsTunnel != nil)
        let fixtureSecret = "fixture"
        #expect(throws: (any Error).self) {
            try SSHFieldSchema.makeConfig(SSHFieldSchema.values(from: stored), fixtureSecret)
        }
    }

    @Test(arguments: [true, false])
    func externalTerminalUsesTheSameTLSOptionAndOriginalSSHIdentity(verify: Bool) throws {
        let config = try SSHConnectionConfig(host: "target.example.com", username: "user", auth: .agent,
            tlsTunnel: SSHTLSTunnelConfig(host: "gateway.example.com", serverName: "tls.example.com",
                                          verifyCertificate: verify))
        let args = SSHCommandBuilder.arguments(for: config, tlsProxyExecutable: "/Applications/My App.app/MacSCP")
        let proxy = try #require(args.first { $0.hasPrefix("ProxyCommand=") })
        #expect(proxy.contains("'/Applications/My App.app/MacSCP'"))
        #expect(proxy.contains("'--internal-tls-proxy' 'gateway.example.com' '443' 'tls.example.com'"))
        #expect(proxy.hasSuffix(verify ? "'verify'" : "'no-verify'"))
        #expect(args.suffix(2) == ["--", "target.example.com"])
        #expect(!args.contains("StrictHostKeyChecking=no"))
        let missing = SSHCommandBuilder.arguments(for: config)
        #expect(missing.contains { $0.hasPrefix("ProxyCommand='/usr/bin/false'") })
    }

    @Test func cannotAccidentallyCombineTwoDifferentTunnelRoutes() throws {
        let tunnel = try SSHTLSTunnelConfig(host: "gateway.example.com")
        #expect(throws: (any Error).self) {
            try SSHConnectionConfig(host: "target.example.com", username: "user", auth: .agent,
                                    jump: .init(host: "jump.example.com", username: "user", auth: .agent),
                                    tlsTunnel: tunnel)
        }
    }
}
