import Citadel
import NIOCore
import Testing

@Suite("Citadel concurrency compatibility")
struct CitadelConcurrencyCompatibilityTests {
    @Test func algorithmMetatypesCanCrossTaskBoundaries() async {
        let algorithms = await Task.detached { SSHAlgorithms.all }.value
        guard case .add(let transports) = algorithms.transportProtectionSchemes,
              case .add(let exchanges) = algorithms.keyExchangeAlgorithms,
              case .add(let keys) = algorithms.publicKeyAlgorihtms else {
            Issue.record("Expected the library's additional algorithm lists")
            return
        }
        #expect(transports.count == 1)
        #expect(exchanges.count == 2)
        #expect(keys.count == 1)
    }

    @Test func sendableModificationsRetainCheckedConditionalConformance() async {
        let modification = await Task.detached {
            SSHAlgorithms.Modification<Int>.add([1, 2])
        }.value
        guard case .add(let values) = modification else {
            Issue.record("Expected an additive modification")
            return
        }
        #expect(values == [1, 2])
    }

    @Test func remoteForwardOverloadsRemainAvailableWithoutOpeningANetworkConnection() {
        // Compile these call shapes in Swift 6, but never invoke them: a real
        // remote forward requires a separately authorized SSH test server.
        let inferredBuffers: (SSHClient) async throws -> Void = { client in
            try await client.withRemotePortForward(host: "localhost", port: 8080) { channel in
                let _: NIOAsyncChannel<ByteBuffer, ByteBuffer> = channel
            }
        }
        let inferredCustomTypes: (SSHClient) async throws -> Void = { client in
            try await client.withRemotePortForward(host: "localhost", port: 8080) {
                (_: NIOAsyncChannel<String, String>) in
            }
        }
        let explicitTypes: (SSHClient) async throws -> Void = { client in
            try await client.withRemotePortForward(
                host: "localhost", port: 8080,
                inboundType: ByteBuffer.self, outboundType: ByteBuffer.self
            ) { _ in }
        }
        _ = (inferredBuffers, inferredCustomTypes, explicitTypes)
    }
}
