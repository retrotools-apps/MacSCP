import Testing
@testable import macSCPCore

@Suite("ConnectionLiveness")
struct ConnectionLivenessTests {
    @Test func tlsKeepAliveIsCappedAtTenSecondsWithoutChangingOrdinaryChecks() throws {
        let tls = try SSHTLSTunnelConfig(host: "gateway.invalid")
        let direct = try SSHConnectionConfig(host: "target.invalid", username: "fixture", auth: .agent)
        let wrapped = try SSHConnectionConfig(host: "target.invalid", username: "fixture", auth: .agent,
                                               tlsTunnel: tls)
        let jumped = try SSHConnectionConfig(host: "target.invalid", username: "fixture", auth: .agent,
            jump: .init(host: "bastion.invalid", username: "fixture", auth: .agent, tlsTunnel: tls))
        #expect(!direct.usesTLSTransport)
        for route in [wrapped, jumped, jumped.redactingSecrets()] {
            #expect(route.usesTLSTransport)
            #expect(LivenessProbePolicy.interval(configured: 60, usesTLS: route.usesTLSTransport) == 10)
            #expect(LivenessProbePolicy.interval(configured: 600, usesTLS: route.usesTLSTransport) == 10)
        }
        #expect(LivenessProbePolicy.interval(configured: 60, usesTLS: false) == 60)
        #expect(LivenessProbePolicy.interval(configured: 600, usesTLS: false) == 600)
    }
    @Test func theProbeTimeoutIsHalfTheIntervalCappedAtTen() {
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 60) == 10)
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 20) == 10)
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 12) == 6)
        // Never zero, never longer than the interval: a probe that outlives its
        // own tick would overlap the next one.
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 1) == 1)
    }

    @Test func aBusyQueueProvesLivenessBetterThanAProbe() {
        #expect(LivenessProbePolicy.decide(queueIsBusy: true, consecutiveFailures: 0) == .skip)
    }

    @Test func theIdleRecheckIsFiveSeconds() {
        // Pinned so the App-layer probe loop (Task 4, fix round 1) reads
        // this constant instead of carrying its own bare literal — a
        // regression here is a behavior change, not just a comment.
        #expect(LivenessProbePolicy.idleRecheckSeconds == 5)
    }

    @Test func theFirstFailureDegradesAndRetriesTheSecondGivesUp() {
        #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) == .probe)
        #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 1) == .probeAgainNow)
        #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 2) == .giveUp)
    }

    @Test func theBackoffDoublesFromFiveAndStopsAtSixty() {
        #expect(ReconnectBackoff.delay(forAttempt: 1) == 5)
        #expect(ReconnectBackoff.delay(forAttempt: 2) == 10)
        #expect(ReconnectBackoff.delay(forAttempt: 3) == 20)
        #expect(ReconnectBackoff.delay(forAttempt: 4) == 40)
        #expect(ReconnectBackoff.delay(forAttempt: 5) == 60)
        #expect(ReconnectBackoff.delay(forAttempt: 99) == 60)
    }
}
