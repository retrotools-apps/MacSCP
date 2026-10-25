import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Pending SSH trust cards must stay visible. Other saved-session failures
/// are alerts over the session overview, without opening an editing form.
/// These tests use real ConnectionViewModel failures and acknowledgement IDs.
@Suite("Detail surface plan", .timeLimit(.minutes(1)))
@MainActor
struct DetailSurfacePlanTests {
    private static let selected = StoredSession(
        name: "selected", kind: .ssh,
        ssh: StoredSSHConfig(host: "target.invalid", username: "tim", authKind: .agent))

    /// Every input at the value an idle, unconnected tab with a sidebar
    /// selection has; each test moves the one it is about.
    private static func surface(
        liveness: ConnectionLiveness? = nil,
        hostKeyPromptPending: Bool = false,
        connectAttemptFailed: Bool = false,
        describesLostConnection: Bool = false,
        unacknowledgedFailure: Bool = false,
        formMode: ConnectionViewModel.FormMode = .new,
        overviewSession: StoredSession? = selected
    ) -> DetailSurface {
        DetailSurfacePlan.surface(
            liveness: liveness, hostKeyPromptPending: hostKeyPromptPending,
            connectAttemptFailed: connectAttemptFailed,
            describesLostConnection: describesLostConnection,
            unacknowledgedFailure: unacknowledgedFailure,
            formMode: formMode, overviewSession: overviewSession)
    }

    /// The form's facts as `ContentView.detailSurface(for:)` reads them.
    private static func surface(of form: ConnectionViewModel, liveness: ConnectionLiveness? = nil) -> DetailSurface {
        surface(
            liveness: liveness, hostKeyPromptPending: form.hostKeyPrompt != nil,
            unacknowledgedFailure: form.unacknowledgedFailure != nil, formMode: form.mode)
    }

    private static func form(
        _ connector: @escaping ConnectionViewModel.Connector = { _, _ in throw CancellationError() }
    ) -> ConnectionViewModel {
        let form = ConnectionViewModel(connector: connector)
        form.host = "target.invalid"
        form.port = "22"
        form.username = "tim"
        form.password = "secret-value"
        return form
    }

    // MARK: - What the overview must never cover

    /// The maintainer's report. The dial is suspended in the host-key
    /// decider; the only way on is the trust card, and the card is inside
    /// the form. Crossed with every liveness, because
    /// `ConnectionSurfacePlan` already forces `.form` for a pending prompt
    /// from every one of them — including `.connecting`, which is where a
    /// sidebar dial actually is when the prompt arrives.
    @Test(arguments: [Optional<ConnectionLiveness>.none, .connecting, .connected, .degraded, .lost])
    func aPendingHostKeyPromptIsNeverCoveredByTheOverview(liveness: ConnectionLiveness?) {
        #expect(Self.surface(liveness: liveness, hostKeyPromptPending: true) == .form)
    }

    /// A rejected host key, a missing key passphrase: the attempt stopped at
    /// a question only a person can answer, and the alert is over the overview.
    @Test func aNeedsPersonFailureUsesTheOverviewWithAnUnacknowledgedAlert() async {
        let rejected = Self.form { _, _ in throw HostKeyError.rejectedByUser }
        _ = await rejected.connect()
        #expect(rejected.lastFailureKind == .needsPerson)
        #expect(Self.surface(of: rejected) == .overview(Self.selected))
        #expect(FormFailureAlertPlan.onAppear(state: rejected.state, unacknowledgedFailure: rejected.unacknowledgedFailure) != nil)

        let passphrase = Self.form { _, _ in throw SSHKeyError.passphraseRequired }
        _ = await passphrase.connect()
        #expect(passphrase.lastFailureKind == .needsPerson)
        #expect(Self.surface(of: passphrase) == .overview(Self.selected))
    }

    /// A refusal decided before any dial: the form's own validation, and
    /// the App's refusal through `showFailure` (a login set or jump session
    /// that no longer resolves, a `fillForm` throw).
    @Test func aPreDialRefusalShowsItsAlertOverTheOverview() async {
        let validation = Self.form()
        validation.host = ""
        _ = await validation.connect()
        #expect(Self.surface(of: validation) == .overview(Self.selected))

        let appRefusal = Self.form()
        appRefusal.showFailure(message: "refused")
        #expect(Self.surface(of: appRefusal) == .overview(Self.selected))
    }

    /// The one update in which the mirror has not yet caught up: the
    /// failure and the cleared prompt arrive together, while `tab.liveness`
    /// still reads `.connecting`. The overview alert must appear immediately.
    /// Read BEFORE the
    /// mirror runs, which is the whole point of this case.
    @Test func aHostKeyRejectWithLivenessStillConnectingShowsTheOverviewAlert() async {
        let form = Self.form { _, _ in throw HostKeyError.rejectedByUser }
        _ = await form.connect()
        #expect(form.hostKeyPrompt == nil)
        #expect(Self.surface(of: form, liveness: .connecting) == .overview(Self.selected))
    }

    /// On a tab describing a dropped connection the mirror sends the same
    /// failure to the lost surface, so the lag keeps its old answer rather
    /// than flashing the form for one update.
    @Test func aLaggingConnectingOnALostTabStaysConnecting() {
        #expect(Self.surface(
            liveness: .connecting, describesLostConnection: true, unacknowledgedFailure: true)
            == .connecting)
    }

    // MARK: - The positive partners

    /// Without this the checks above would pass over a plan that had
    /// stopped offering the overview at all.
    @Test func anIdleUnconnectedTabWithASelectionShowsTheOverview() {
        #expect(Self.surface() == .overview(Self.selected))
    }

    /// Dismissing the text keeps the same overview and clears only the alert.
    @Test func dismissingTheFailureBringsTheOverviewBack() throws {
        let form = Self.form()
        form.showFailure(message: "refused")
        #expect(Self.surface(of: form) == .overview(Self.selected))
        let id = try #require(form.unacknowledgedFailure)
        form.acknowledgeFailure(id)
        #expect(Self.surface(of: form) == .overview(Self.selected))
        #expect(FormFailureAlertPlan.onAppear(state: form.state, unacknowledgedFailure: form.unacknowledgedFailure) == nil)
    }

    // MARK: - Everything else is as it was

    /// A dial that failed on the wire has its own surface; once the person
    /// has left it ("Edit" clears `connectFailure`), its text has been read
    /// and nothing holds the overview back.
    @Test func aWireFailureAlreadyShownElsewhereDoesNotHoldTheOverviewBack() async {
        let form = Self.form { _, _ in throw RemoteFSError.connectionFailed(reason: "unreachable") }
        _ = await form.connect()
        #expect(form.lastFailureKind == .other)
        #expect(Self.surface(of: form) == .overview(Self.selected))
    }

    @Test func anEditingFormIsNeverReplacedByTheOverview() {
        #expect(Self.surface(formMode: .edit(sessionID: Self.selected.id)) == .form)
    }

    @Test func noSelectionShowsTheForm() {
        #expect(Self.surface(overviewSession: nil) == .form)
        #expect(Self.surface(unacknowledgedFailure: true, overviewSession: nil) == .form)
        #expect(Self.surface(unacknowledgedFailure: true, formMode: .edit(sessionID: Self.selected.id)) == .form)
    }

    @Test func aMissingPasswordKeepsTheSessionOverviewBehindTheAlertBeforeAndAfterOK() async throws {
        let form = Self.form()
        form.password = ""
        _ = await form.connect()
        let alert = try #require(FormFailureAlertPlan.onAppear(state: form.state, unacknowledgedFailure: form.unacknowledgedFailure))
        #expect(!alert.message.isEmpty)
        #expect(Self.surface(of: form) == .overview(Self.selected))
        #expect(form.mode == .new)
        form.acknowledgeFailure(try #require(alert.failureID))
        #expect(Self.surface(of: form) == .overview(Self.selected))
        #expect(FormFailureAlertPlan.onAppear(state: form.state, unacknowledgedFailure: form.unacknowledgedFailure) == nil)
    }

    /// The three attempt surfaces answer before the overview is considered,
    /// exactly as `ConnectionSurfacePlan` answers them.
    @Test func theAttemptSurfacesAnswerFirst() {
        #expect(Self.surface(liveness: .connecting) == .connecting)
        #expect(Self.surface(liveness: .lost) == .lost)
        #expect(Self.surface(connectAttemptFailed: true) == .failed)
    }
}
