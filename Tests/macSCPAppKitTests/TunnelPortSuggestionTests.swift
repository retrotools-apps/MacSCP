import Darwin
import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Tunnel port suggestions")
struct TunnelPortSuggestionTests {
    @Test func searchesDownwardsAndNeverProbesConfiguredPorts() {
        var checked: [Int] = []
        let port = TunnelPortSuggestion.firstAvailable(excluding: [65534, 65532]) {
            checked.append($0)
            return $0 == 65531
        }
        #expect(port == 65531)
        #expect(checked == [65533, 65531])
    }

    @Test func noAvailablePortDoesNotInventASuggestion() {
        let port = TunnelPortSuggestion.firstAvailable(excluding: []) { _ in false }
        #expect(port == nil)
    }

    @Test func excludesSavedLocalRemoteAndSOCKSListeners() async throws {
        let profiles: [TunnelProfile] = [
            .init(sessionID: UUID(), name: "Local", kind: .local(bind: "127.0.0.1", localPort: 65534, host: "test.example", remotePort: 80)),
            .init(sessionID: UUID(), name: "Remote", kind: .remote(bind: "127.0.0.1", remotePort: 65533, localHost: "127.0.0.1", localPort: 80)),
            .init(sessionID: UUID(), name: "SOCKS", kind: .dynamic(bind: "::1", localPort: 65532))
        ]
        let port = try #require(await TunnelPortSuggestion.suggest(bind: "127.0.0.1", profiles: profiles))
        #expect(port <= 65531)
        #expect(port >= 1)
    }

    @Test func actualOccupiedSocketIsSkippedAndProbeSocketIsReleased() async throws {
        let first = try #require(await TunnelPortSuggestion.suggest(bind: "127.0.0.1", profiles: []))
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(first).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(result == 0)
        guard result == 0 else { return }
        let second = try #require(await TunnelPortSuggestion.suggest(bind: "127.0.0.1", profiles: []))
        #expect(second != first)
    }

    @Test func invalidAddressDoesNotResolveOrProposeAPort() async {
        let port = await TunnelPortSuggestion.suggest(bind: "not-a-local-address.example", profiles: [])
        #expect(port == nil)
    }
}
