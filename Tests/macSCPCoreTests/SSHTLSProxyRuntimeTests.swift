import Foundation
import Testing
@testable import macSCPCore

private final class TLSProxyBundleAnchor: NSObject {}

@Suite("SSH TLS proxy, real local TLS", .timeLimit(.minutes(1)))
struct SSHTLSProxyRuntimeTests {
    @Test(arguments: [true, false], [true, false])
    func nativeSFTPUsesTheGatewayAndTheSameCertificatePolicy(verify: Bool, viaJump: Bool) async throws {
        // This TLS peer deliberately is not an SSH server. Receiving the
        // client's SSH identification proves transport routing/encryption;
        // the following malformed greeting must fail before authentication.
        let server = try await LoopbackTLSStub.make(response: "not an SSH server\r\n")
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-native-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tls = try SSHTLSTunnelConfig(host: "127.0.0.1", port: server.port,
                                       serverName: "localhost", verifyCertificate: verify)
        let jump: SSHConnectionConfig.Jump? = viaJump ? .init(
            host: "unresolved-bastion.invalid", username: "fixture", auth: .password("fixture"),
            tlsTunnel: tls) : nil
        let config = try SSHConnectionConfig(host: "unresolved-target.invalid", username: "fixture",
            auth: .password("fixture"), jump: jump, tlsTunnel: viaJump ? nil : tls)
        do {
            let fs = try await CitadelFileSystem.connect(config: config, connectTimeout: .seconds(2),
                knownHosts: KnownHostsStore(directory: directory), onUnknownHostKey: .asking { _ in false })
            await fs.disconnect()
            Issue.record("A non-SSH peer must not authenticate")
        } catch {
            // Certificate rejection or the deliberately malformed SSH peer.
        }
        if verify {
            #expect(server.requests.isEmpty)
        } else {
            #expect(server.requests.contains { $0.contains("SSH-2.0-") })
        }
    }

    @Test(arguments: [true, false])
    func externalOpenSSHJumpUsesTheTLSHelperAndCertificatePolicy(verify: Bool) async throws {
        let server = try await LoopbackTLSStub.make(response: "invalid key exchange\r\n",
                                                   greeting: "SSH-2.0-local-fixture\r\n")
        defer { server.stop() }
        let executable = Bundle(for: TLSProxyBundleAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("MacSCP")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-jump-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two OpenSSH ProxyCommand parsers must preserve quotes and literal tokens.
        let helper = directory.appendingPathComponent("macscp %h ' helper")
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: executable)
        let tls = try SSHTLSTunnelConfig(host: "127.0.0.1", port: server.port,
                                       serverName: "localhost", verifyCertificate: verify)
        let config = try SSHConnectionConfig(host: "target.invalid", username: "fixture", auth: .agent,
            jump: .init(host: "bastion.invalid", username: "fixture", auth: .agent, tlsTunnel: tls))
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-F", "/dev/null", "-o", "BatchMode=yes"]
                + SSHCommandBuilder.arguments(for: config, tlsProxyExecutable: helper.path),
            timeout: .seconds(20))
        #expect(result.status != 0)
        if verify {
            #expect(server.requests.isEmpty)
        } else {
            #expect(server.requests.contains { $0.contains("SSH-2.0-") },
                    Comment(rawValue: String(decoding: result.stderr, as: UTF8.self)))
        }
    }

    @Test(arguments: [true, false])
    func certificateVerificationIsActuallyEnforcedByTheExecutable(verify: Bool) async throws {
        let server = try await LoopbackTLSStub.make(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        defer { server.stop() }
        let executable = Bundle(for: TLSProxyBundleAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("MacSCP")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let request = Data("GET /tls-proxy-test HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let result = try await SubprocessRunner.run(executable,
            arguments: ["--internal-tls-proxy", "127.0.0.1", String(server.port), "localhost",
                        verify ? "verify" : "no-verify"],
            stdin: request, timeout: .seconds(20))
        if verify {
            #expect(result.status != 0)
            #expect(server.requests.isEmpty)
            #expect(result.stdout.isEmpty)
            #expect(!result.stderr.isEmpty)
        } else {
            #expect(result.status == 0)
            #expect(String(decoding: result.stdout, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
            #expect(server.requests.contains { $0.contains("GET /tls-proxy-test ") })
        }
    }
}
