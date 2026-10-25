import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore
@testable import MacSCPAppKit

@MainActor
@Suite("Paired remotes over two SSH connections", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
struct RemotePairSSHIntegrationTests {
    @Test func copiesBothDirectionsUsingOnlyTheExistingConnections() async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let knownHosts = KnownHostsStore(directory: fixture.root.appendingPathComponent("known-hosts"))
        let source = try await connect(port: 2222, knownHosts: knownHosts)
        let destination: CitadelFileSystem
        do { destination = try await connect(port: 2223, knownHosts: knownHosts) }
        catch { await source.disconnect(); throw error }
        let directory = "/config/macscp-paired-\(UUID().uuidString)"
        var failure: (any Error)?
        do {
            try await source.createDirectory(at: directory)
            try await destination.createDirectory(at: directory)
            fixture.attach(fixture.left, path: directory, fs: source)
            fixture.attach(fixture.right, path: directory, fs: destination)
            let leftID = fixture.left.session?.id
            let rightID = fixture.right.session?.id
            let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
            for reverse in [false, true] {
                let input = reverse ? destination : source
                let output = reverse ? source : destination
                let owner = reverse ? fixture.right : fixture.left
                let name = reverse ? "return file.bin" : "forward file.bin"
                let bytes = Data((0..<(TransferChunk.size * 9 + 73)).map { UInt8(($0 * 7) % 251) })
                try await input.write(path: directory + "/" + name, mode: .overwrite,
                    contents: AsyncThrowingStream { continuation in
                        continuation.yield(bytes)
                        continuation.finish()
                    })
                let item = try await input.stat(path: directory + "/" + name)
                #expect(pair.transfer([item], from: owner))
                try await pollUntil("SSH paired copy completes") {
                    !owner.transferQueue.items.isEmpty && owner.transferQueue.items.allSatisfy { $0.status.isTerminal }
                }
                #expect(owner.transferQueue.items.allSatisfy { $0.status == .finished && $0.crossRemote })
                var received = Data()
                for try await chunk in try await output.readStream(path: directory + "/" + name, fromOffset: 0) {
                    received.append(chunk)
                }
                #expect(received == bytes)
            }
            #expect(fixture.left.session?.id == leftID)
            #expect(fixture.right.session?.id == rightID)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.leftDirectory.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.rightDirectory.path).isEmpty)
        } catch { failure = error }
        await fixture.left.transferQueue.cancelAll(reason: .userRequested)
        await fixture.right.transferQueue.cancelAll(reason: .userRequested)
        try? await source.deleteTree(at: directory)
        try? await destination.deleteTree(at: directory)
        await source.disconnect()
        await destination.disconnect()
        if let failure { throw failure }
    }

    private func connect(port: Int, knownHosts: KnownHostsStore) async throws -> CitadelFileSystem {
        // Development-only Compose fixtures. Consent is explicit and confined to
        // a fresh known-hosts store; application trust handling is not changed.
        let configuration = try SSHConnectionConfig(host: "127.0.0.1", port: port, username: "testuser",
            auth: .password("testpass"))
        return try await CitadelFileSystem.connect(config: configuration, connectTimeout: .seconds(15),
            knownHosts: knownHosts, onUnknownHostKey: .asking { _ in true })
    }
}
