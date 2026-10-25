import Foundation
import Testing
@testable import macSCPCore

@Suite("Direct TCP/IP diagnostic privacy")
struct DirectTCPIPDiagnosticSummaryTests {
    @Test func connectFailedPreservesTheTargetWithoutClaimingAClosedPort() {
        let failure = SSHForwardingConnection.forwardingFailure(
            for: DirectTCPIPRejection(reasonCode: 2), host: "service.test", port: 8000)
        #expect(failure == .destinationUnreachable(host: "service.test", port: 8000))
        #expect(TunnelFailureKind(failure) == .destinationUnreachable(host: "service.test", port: 8000))
        #expect(SOCKS5ReplyCode(failure) == .hostUnreachable)
    }

    @Test(arguments: [UInt32(1), 3, 4, 99])
    func otherRefusalsAreNotMisreportedAsAnUnreachableDestination(_ code: UInt32) {
        let failure = SSHForwardingConnection.forwardingFailure(
            for: DirectTCPIPRejection(reasonCode: code), host: "service.test", port: 8000)
        guard case .channelOpenFailed = failure else {
            Issue.record("A different SSH refusal was classified as a destination failure")
            return
        }
    }

    @Test(arguments: [UInt32(1), 2, 3, 4, 99])
    func preservesOnlyTheSSHRefusalCode(_ code: UInt32) {
        #expect(DirectTCPIPDiagnosticSummary.message(for: DirectTCPIPRejection(reasonCode: code))
            == "ssh-channel-rejected code=\(code)")
    }

    private struct PayloadError: Error, CustomStringConvertible, LocalizedError {
        let payload: String
        var description: String { payload }
        var errorDescription: String? { payload }
    }

    @Test func arbitraryErrorDescriptionsNeverReachTheSummary() {
        let payload = "private-fixture-" + UUID().uuidString
        let summary = DirectTCPIPDiagnosticSummary.message(for: PayloadError(payload: payload))
        #expect(summary.hasPrefix("errorType="))
        #expect(summary.contains("PayloadError"))
        let containsPayload = summary.contains(payload)
        #expect(!containsPayload)
    }
}
