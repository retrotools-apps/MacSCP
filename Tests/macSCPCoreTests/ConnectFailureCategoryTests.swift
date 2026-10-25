import Foundation
import Testing
@testable import macSCPCore

@Suite("Actionable connection failure categories")
struct ConnectFailureCategoryTests {
    @Test func targetAndJumpAuthenticationAreDistinct() {
        #expect(ConnectFailureCategory.classify(RemoteFSError.authenticationFailed) == .authentication)
        #expect(ConnectFailureCategory.classify(RemoteFSError.jumpAuthenticationFailed) == .jumpAuthentication)
        #expect(ConnectFailureCategory.classify(RemoteFSError.connectionFailed(reason: "fixture")) == .network)
        #expect(ConnectFailureCategory.classify(SSHKeyError.passphraseRequired) == .key)
        #expect(ConnectFailureCategory.classify(HostKeyError.rejectedByUser) == .hostKey)
    }

    @Test func typedNetworkErrorsAreNotGuessedFromTheirText() {
        #expect(ConnectFailureCategory.classify(URLError(.timedOut)) == .timeout)
        #expect(ConnectFailureCategory.classify(URLError(.cannotFindHost)) == .nameResolution)
        #expect(ConnectFailureCategory.classify(URLError(.notConnectedToInternet)) == .network)
        #expect(ConnectFailureCategory.classify(URLError(.serverCertificateUntrusted)) == .tls)
        #expect(ConnectFailureCategory.classify(RemoteFSError.protocolError(reason: "authentication failed")) == .unknown)
    }

    @Test @MainActor func aRealConnectPublishesTheCategoryAndTheNextAttemptClearsIt() async {
        let form = ConnectionViewModel(connector: { _, _ in throw RemoteFSError.authenticationFailed })
        form.host = "fixture.invalid"
        form.username = "fixture"
        form.password = "fixture"
        _ = await form.connect()
        #expect(form.lastFailureCategory == .authentication)
        form.password = ""
        _ = await form.connect()
        #expect(form.lastFailureCategory == nil)
    }
}
