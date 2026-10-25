import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Connection form regressions")
@MainActor
struct ConnectionFormRegressionTests {
    @Test func cancellingAnIncompleteNewFormDoesNotValidateOrDial() {
        let form = ConnectionViewModel(connector: { _, _ in
            Issue.record("Cancelling a form must not open a connection")
            throw CancellationError()
        })
        let tab = SessionTab(connectionViewModel: form, certificateBridge: CertificatePromptBridge(),
                             limiter: BandwidthLimiter(), maxConcurrent: 2)
        form.host = ""
        form.shouldSaveSession = true
        form.saveName = ""
        form.password = "discarded-fixture"
        tab.dismissNewConnectionForm()
        #expect(tab.isNewConnectionFormDismissed)
        #expect(form.state == .idle)
        #expect(form.password.isEmpty)
        #expect(!form.shouldSaveSession)
    }

    @Test func keySelectionStartsInSSHWithoutATypedPath() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        #expect(SSHKeyFileSelection.initialDirectory(currentPath: "", home: home).path == "/Users/fixture/.ssh")
        #expect(SSHKeyFileSelection.initialDirectory(currentPath: "~/keys/key", home: home).path == "/Users/fixture/keys")
        #expect(SSHKeyFileSelection.initialDirectory(currentPath: "/other/keys/key", home: home).path == "/other/keys")
        #expect(SSHKeyFileSelection.initialDirectory(currentPath: "key", home: home).path == "/Users/fixture/.ssh")
    }

    @Test func aDismissedFormCannotHideAHostKeyTrustDecision() {
        #expect(DetailSurfacePlan.surface(liveness: nil, hostKeyPromptPending: false,
            connectAttemptFailed: false, describesLostConnection: false,
            unacknowledgedFailure: false, formMode: .new, overviewSession: nil,
            newFormDismissed: true) == .dismissedForm)
        #expect(DetailSurfacePlan.surface(liveness: .connecting, hostKeyPromptPending: true,
            connectAttemptFailed: false, describesLostConnection: false,
            unacknowledgedFailure: false, formMode: .new, overviewSession: nil,
            newFormDismissed: true) == .form)
    }

    @Test func theCompactWindowFitsTheFormAndTheWidestSidebar() {
        #expect(MainWindowSizePlan.formSize.width >= CGFloat(SettingsStore.sidebarWidthRange.upperBound) + 500)
    }

    @Test func appKitDoesNotStartInsideAnAsyncMainJob() throws {
        let main = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPMain/Main.swift")
        let code = try SourceCorpus.code(of: main)
        #expect(code.contains("static func main()"))
        #expect(code.contains("AppMain.main()"))
        #expect(code.contains("SSHTLSTransport.runProxyMainIfRequested"))
        #expect(!code.contains("static func main() async"))
        #expect(!code.contains("await"))
    }
}
