import Foundation
import Observation
import SwiftUI
import macSCPCore

struct BrowserSession {
    /// Identifies this tab's edit-session temp subtree (M5e/T4) — shared
    /// with `editManager`'s `sessionID` so both name the same directory.
    let id: UUID
    let localFS: LocalFileSystem
    let remoteFS: any RemoteFileSystem
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
    let editManager: EditSessionManager
    /// The remote home-directory path resolved once at connect (connection-
    /// liveness plan, Task 4). `ContentView.startSession`'s two callers
    /// already run `homeDirectoryPath()` before building this session and
    /// hand the result in as `startPath` — storing it here too lets the
    /// liveness probe `stat` it without a second round trip to find its own
    /// target.
    let homePath: String
    var localChecksums = ChecksumLedger()
    var remoteChecksums = ChecksumLedger()
}

/// One window tab (M8a): bundles what used to be window-wide state, per
/// tab. Reference type — background tabs stay alive in `TabsViewModel`
/// while only the active tab is mounted. Per-window scope: this type and
/// everything it stores (`liveness` included) belongs to one window's tab,
/// never to an app-wide singleton — this project's standing invariant for
/// connection/session state.
@MainActor
@Observable
final class SessionTab: Identifiable {
    let id = UUID()
    let fileWindows = FileInspectionWindows()
    let connectionViewModel: ConnectionViewModel
    var isNewConnectionFormDismissed = false

    /// Cancel is not a submit: incomplete fields and secrets are discarded
    /// without validation, saving, Keychain access or network activity.
    func dismissNewConnectionForm() {
        connectionViewModel.cancelConnecting()
        connectionViewModel.endEditing()
        isNewConnectionFormDismissed = true
    }
    var session: BrowserSession?
    /// A presentation link only. Each tab continues to own its own connection.
    var remotePair: RemotePanePair?
    var isDisconnecting = false
    var remoteTransferErrorMessage: String?
    @ObservationIgnored var disconnectionWaiters: [CheckedContinuation<Void, Never>] = []
    let transferQueue = TransferQueueViewModel()
    let conflictBridge = ConflictPromptBridge()
    /// Drives the certificate-trust prompt for this tab's WebDAV/S3 connect
    /// attempts (M21/T10) — see `CertificatePromptBridge`'s own doc comment
    /// for why it is constructed OUTSIDE this initializer and simply handed
    /// in, unlike `conflictBridge` above.
    let certificateBridge: CertificatePromptBridge
    /// Drives the "send credentials unencrypted?" confirmation for this
    /// tab's connect attempts (M21/T10): `true` while
    /// `PlaintextTransportGate.requiresConfirmation` is true and the App is
    /// waiting for the user's answer. Same single-continuation shape as
    /// `CertificatePromptBridge` above, but plain properties on the tab
    /// itself rather than a separate bridge type: the dialog needs no
    /// candidate payload (its text is the same for every plaintext
    /// endpoint), so there is nothing a separate type would encapsulate that
    /// isn't already just "is one pending, and how do I resolve it".
    var plaintextConfirmationPending = false
    private var plaintextContinuation: CheckedContinuation<Bool, Never>?
    /// Set by the connector closure right before dispatching a connect whose
    /// transport is plaintext AND the user just confirmed the risk dialog;
    /// reset to `false` at the START of every connect attempt (before the
    /// gate is even consulted), so a previous connect's confirmation — even
    /// an ad-hoc one, which has no audit trail to write it into (see
    /// `attachAuditRecorder`'s own doc comment) — can never leak into a
    /// later, unrelated connect's audit record. Consumed (read and reset) by
    /// `ContentView.attachAuditRecorder`, the one place a `sessionID` (and
    /// with it, an `AuditRecorder` to write to) exists.
    var pendingPlaintextConfirmation = false
    var transfersPanelVisible = false

    /// Display name while connected (stored session name or "user@host").
    /// The tab strip and the window title read it through
    /// `ContentView.tabTitle(for:)`, where it is the first rule of
    /// `TabTitlePlan.title`; `displayTitle` below reads it directly.
    var titleName: String?
    /// Transient error from a failed "open in editor" attempt (M5e/T4) —
    /// cleared on the next successful open or dismissed via its close button.
    var editErrorMessage: String?
    /// Stored session this tab is connected to (sidebar highlight).
    var activeStoredSessionID: UUID?
    var restoredSessionID: UUID?
    /// Folder browsing belongs to this tab, not to other windows or tabs.
    var overviewGroupID: UUID?
    /// Per-session audit recorder (M9b) — set only when this tab connects to
    /// a STORED session (never for an ad-hoc connect), alongside
    /// `activeStoredSessionID`; nilled in `teardown(_:)` after the final
    /// `recordDisconnected()` call. See `ContentView.attachAuditRecorder`.
    var auditRecorder: AuditRecorder?
    var isReconnecting = false
    /// Identifies the current reconnect attempt for THIS tab (connection-
    /// liveness plan, Task 6 fix round 1) — the App-layer counterpart of
    /// `ConnectionViewModel.currentAttempt` (Core), for the identical
    /// reason: `isReconnecting` locks the sidebar and rejects a double-
    /// click reconnect (`ContentView.connect(in:stored:)`'s own top-of-
    /// function guard), and it must be released the moment Cancel runs —
    /// see `ConnectingAttemptView`'s `onCancel` in `ContentView+Detail
    /// .swift` — not only once the abandoned attempt's own wrapping `Task`
    /// finally reaches its `defer`. Reassigned both there and at the start
    /// of `connect(in:stored:)`, so a Task whose own attempt is no longer
    /// current cannot clear a NEWER attempt's `isReconnecting` flag out
    /// from under it when its own deferred cleanup finally runs.
    var reconnectAttempt = UUID()
    /// Last-seen value of `transferQueue.totalFailureCount` while this tab was
    /// active — the attention indicator (T4) lights up when
    /// `totalFailureCount` exceeds it. `totalFailureCount` is monotonic (it
    /// never decreases, unlike the old item-based `failedCount`), so this
    /// watermark correctly detects a NEW failure even after a background
    /// tab's completed items were swept by `clearCompleted()` (M8a T5 review,
    /// finding 2).
    var seenFailureCount = 0

    /// This tab's "transfer failed" notification state (next build of
    /// 2026-09-17, Task 7; a latch since fix round 1): the failures it has
    /// answered for, and whether a posted notification is still unseen —
    /// see `ErrorNotificationPlan.TransferFailureLatch` and
    /// `ContentView.notifyTransferFailures()`. On the tab rather than on a
    /// window, so a tab that moves to another window does not notify again
    /// about failures it already had.
    var transferFailureLatch = ErrorNotificationPlan.TransferFailureLatch()

    var isConnected: Bool { session != nil }

    /// Whether this tab is the window's reusable, unsaved connection draft.
    /// Typed form values deliberately do not disqualify it: pressing New Tab
    /// again must return to that draft rather than create a second tab and
    /// abandon what the user already entered.
    var isReusableNewConnectionDraft: Bool {
        !isConnected
            && !isReconnecting
            && connectionViewModel.mode == .new
            && connectionViewModel.state == .idle
            && connectionViewModel.hostKeyPrompt == nil
            && liveness == nil
            && lostConnection == nil
            && connectFailure == nil
            && activeStoredSessionID == nil
            && restoredSessionID == nil
            && overviewGroupID == nil
    }
    var commanderActiveSide: BrowserPaneSide = .local

    var liveness: ConnectionLiveness?

    /// Why the last liveness probe on this tab's current session failed, or
    /// `nil` when it came back alive or none has failed yet (lost-connection
    /// cause, 2026-09-19).
    ///
    /// Two writers: `LivenessProbeStep.perform` writes each probe's answer
    /// here, under the same guard as its `liveness` write, and
    /// `ContentView.startSession` clears it for a fresh session.
    /// `ContentView.handleLivenessGiveUp(_:)` reads it — the probe that
    /// failed last is the one the give-up follows — into its log line and
    /// into `LostConnection.probeFailure`.
    var lastProbeFailure: LivenessProbeFailure?

    /// What the lost-connection surface describes and offers while
    /// `liveness` is `.lost` (connection-liveness plan, Task 7).
    ///
    /// Separate from `liveness` and not derived from it: `.lost` says THAT
    /// the connection is gone, this says what happened and — the part that
    /// cannot be recovered afterwards — WHICH stored session to redial.
    /// `ContentView.teardown(_:)` clears `activeStoredSessionID` along with
    /// the session itself, so by the time `.lost` is written there is no
    /// longer anything on this tab naming the connection that just dropped;
    /// `ContentView.handleLivenessGiveUp(_:)` captures it BEFORE calling
    /// teardown and writes this afterwards, in the same order and for the
    /// same reason `.lost` itself is written afterwards.
    ///
    /// Seven writers, counted while writing this sentence (the first
    /// version of this comment named four of them, which is how a reviewer
    /// found it):
    /// - `ContentView.handleLivenessGiveUp(_:)` opens an episode, after
    ///   `teardown(_:)` has run and for the same reason `.lost` is written
    ///   there rather than before it.
    /// - `ContentView.teardown(_:)` clears it, unconditionally, for its
    ///   other callers — every one of them a deliberate "leave this
    ///   connection", with no drop left to describe.
    /// - `ContentView.startSession` clears it: the tab has a live session
    ///   again, so the record of the one that dropped goes with it, attempt
    ///   counter included.
    /// - `ContentView.dismissLostConnection(_:)` clears it together with
    ///   `liveness`, when the user leaves the surface for the form.
    /// - `ContentView.connect(in:stored:)` clears it when the connect names
    ///   a DIFFERENT stored session — the user has moved on, and that
    ///   attempt's failure belongs to what they just asked for.
    /// - `ConnectAttemptLivenessMirror` writes back the `reason` a failed
    ///   attempt earned (`ConnectAttemptLivenessPlan.write`'s answer), in
    ///   the same step as the `liveness` it explains.
    /// - `ReconnectRunner` increments `automaticAttempts`, before the dial
    ///   it is about to start.
    ///
    /// Five of those seven also write `liveness`, in the same step, and
    /// the overlap was recounted here rather than carried over:
    /// `handleLivenessGiveUp`, `teardown`, `startSession`,
    /// `dismissLostConnection` and the mirror. That is what keeps the two
    /// values from drifting into describing different realities. The two
    /// that do not — `connect(in:stored:)`'s conditional clear and the
    /// runner's counter — touch nothing `liveness` describes.
    var lostConnection: LostConnection?

    /// This tab's failed connect ATTEMPT (failed-connect surface plan,
    /// Task 3) — the sibling of `lostConnection` above, and deliberately a
    /// separate value rather than a fifth `ConnectionLiveness` case: a
    /// connection that never existed is a different thing from one that
    /// dropped, and the tab-strip dot reads `liveness` for a tab that has
    /// no connection either way.
    ///
    /// Three writers, counted while writing this sentence:
    /// - `ConnectAttemptLivenessMirror` SETS it, from
    ///   `ConnectAttemptLivenessPlan.write`'s `.failedConnect` answer, and
    ///   clears it on `.connecting` (a new attempt speaks for the tab now)
    ///   and on `.clear`.
    /// - `ContentView.dismissConnectFailure(_:)` clears it — the way off
    ///   this surface back to the form, from the surface's own Edit control
    ///   and from the sidebar commands that fill the form.
    /// - `ContentView.teardown(_:reason:)` clears it, for the same reason
    ///   it clears `liveness` and `lostConnection`: every caller of that
    ///   function is leaving this connection on purpose.
    ///
    /// The third one was missing until review round 1, and the sentence
    /// that stood here is why. It argued that `teardown(_:)` cannot matter
    /// because "a tab whose session is being torn down HAD a session, so
    /// its next failure is a `lostConnection`, not this" — true of the
    /// tab's next failure, and irrelevant to the one already on record.
    /// `performClose` tears a tab down and, on the LAST tab, does not
    /// remove it; the failed-connect surface therefore survived its own
    /// Close button, measured, while the window shrank around it. A
    /// premise that is true about the future and silently read as a claim
    /// about the present is the shape of that mistake.
    ///
    /// `ContentView.newConnection()` and `formTarget()` reach it only
    /// THROUGH `dismissConnectFailure(_:)`, which is why they are not a
    /// fourth and fifth writer.
    var connectFailure: ConnectFailure?

    var displayTitle: String {
        (titleName.map(TabTitle.named) ?? .newConnection).tabLabel
    }

    /// Wires the tab-owned queue on construction: shared limiter, initial
    /// concurrency, and the conflict decider onto the tab's OWN bridge —
    /// exactly once per tab (no re-wiring per connect).
    init(
        connectionViewModel: ConnectionViewModel,
        certificateBridge: CertificatePromptBridge,
        limiter: BandwidthLimiter,
        maxConcurrent: Int
    ) {
        self.connectionViewModel = connectionViewModel
        self.certificateBridge = certificateBridge
        transferQueue.limiter = limiter
        transferQueue.maxConcurrent = maxConcurrent
        let bridge = conflictBridge
        transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }
    }

    /// Decider side of the plaintext-transport confirmation (M21/T10):
    /// presents the dialog and suspends until `resolvePlaintextConfirmation`
    /// answers it. Cancellation-safe, same shape as
    /// `CertificatePromptBridge.ask(_:)`.
    func confirmPlaintext() async -> Bool {
        plaintextConfirmationPending = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    plaintextConfirmationPending = false
                    continuation.resume(returning: false)
                    return
                }
                plaintextContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePlaintextConfirmation(confirmed: false)
            }
        }
    }

    /// Called by the UI once the user answers the plaintext confirmation.
    func resolvePlaintextConfirmation(confirmed: Bool) {
        guard let continuation = plaintextContinuation else { return }
        plaintextContinuation = nil
        plaintextConfirmationPending = false
        continuation.resume(returning: confirmed)
    }

    /// Resets `pendingPlaintextConfirmation` — called by the connector
    /// closure at the START of every connect attempt, before the gate is
    /// even consulted. A plain `@MainActor`-isolated method (not a direct
    /// property write from the closure) so the cross-actor call goes through
    /// the normal `await`-hop instead of a bare assignment, which the
    /// connector closure — a `@Sendable` value handed to Core — cannot
    /// perform directly. See the property's own doc comment.
    func resetPendingPlaintextConfirmation() { pendingPlaintextConfirmation = false }

    /// Marks that this connect's plaintext confirmation was answered "yes" —
    /// called by the connector closure right before dispatching the actual
    /// connect. Same "isolated method, not a bare write" reasoning as
    /// `resetPendingPlaintextConfirmation()` above.
    func markPlaintextConfirmed() { pendingPlaintextConfirmation = true }

}

extension SessionTab {
    /// A write path to one side's checksum ledger, naming the session it
    /// belongs to at the moment it is made (re-review N2).
    ///
    /// The naming is the whole point. A digest arrives long after it was
    /// asked for — that is what a hash of a large file over a connection
    /// is — and the surfaces that ask do not stop when the pane goes away:
    /// the info sheet's compute runs in an unstructured task nothing
    /// cancels, and a row of a run that is already awaiting still finishes.
    /// A write that resolved `session` at the moment it lands would
    /// therefore drop a digest of the OLD connection's bytes into the ledger
    /// of whatever session happens to be current, i.e. into the new one
    /// after a reconnect — and two hosts can easily hold a file at the same
    /// path with the same size and the same whole-second timestamp.
    ///
    /// So both halves compare `id` first: a stale binding writes nothing,
    /// and reads as empty rather than as the new connection's values. This
    /// is the same defence, for the same reason, that the liveness probe
    /// already applies to its own in-flight answers.
    ///
    /// It exists as a named method rather than as two closure literals at
    /// the call sites so that "the pane's ledger comes from a session" is a
    /// property a test can hold — and does, in `SessionTabTests` — instead
    /// of a shape someone has to re-read a view body to check.
    func checksumLedgerBinding(
        for side: BrowserPaneSide, in session: BrowserSession
    ) -> Binding<ChecksumLedger> {
        let sessionID = session.id
        return Binding(
            get: { [weak self] in
                guard let current = self?.session, current.id == sessionID else {
                    return ChecksumLedger()
                }
                switch side {
                case .local: return current.localChecksums
                case .remote: return current.remoteChecksums
                }
            },
            set: { [weak self] newValue in
                guard let self, self.session?.id == sessionID else { return }
                switch side {
                case .local: self.session?.localChecksums = newValue
                case .remote: self.session?.remoteChecksums = newValue
                }
            })
    }
}
