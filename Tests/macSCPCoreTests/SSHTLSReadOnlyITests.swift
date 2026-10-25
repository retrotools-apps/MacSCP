import Foundation
import Testing
@testable import macSCPCore

/// Explicit opt-in only: authenticate and read home metadata, never run a
/// remote command or write remote data. Supply a fingerprint independently
/// verified through an existing trusted SSH route, not an accept-anything rule.
@Suite("SSH TLS native read-only integration", .timeLimit(.minutes(1)),
       .enabled(if: ProcessInfo.processInfo.environment["MACSCP_TLS_ITEST"] == "1"))
struct SSHTLSReadOnlyITests {
    @Test func nativeSFTPAuthenticatesAndReadsHomeThroughTLS() async throws {
        let env = ProcessInfo.processInfo.environment
        func required(_ key: String) throws -> String {
            let value = try #require(env[key], "Missing integration test input: \(key)")
            #expect(!value.isEmpty)
            return value
        }
        let host = try required("MACSCP_TLS_TARGET")
        let gateway = try required("MACSCP_TLS_GATEWAY")
        let username = try required("MACSCP_TLS_USER")
        let keyPath = try required("MACSCP_TLS_KEY")
        let expectedFingerprint = try required("MACSCP_TLS_FINGERPRINT")
        let tunnel = try SSHTLSTunnelConfig(host: gateway,
            port: Int(env["MACSCP_TLS_PORT"] ?? "443") ?? 443,
            serverName: env["MACSCP_TLS_SNI"] ?? gateway,
            verifyCertificate: env["MACSCP_TLS_VERIFY"] != "0")
        let config = try SSHConnectionConfig(host: host, username: username,
            auth: .privateKey(keyPath: keyPath, passphrase: nil), tlsTunnel: tunnel)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-tls-readonly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fs = try await CitadelFileSystem.connect(config: config, connectTimeout: .seconds(10),
            knownHosts: KnownHostsStore(directory: directory),
            onUnknownHostKey: .asking { $0.fingerprintSHA256 == expectedFingerprint })
        do {
            let home = try await fs.homeDirectoryPath()
            #expect(home.hasPrefix("/"))
            let attributes = try await fs.stat(path: home)
            #expect(attributes.isDirectory)
            await fs.disconnect()
        } catch {
            await fs.disconnect()
            throw error
        }
    }
}
