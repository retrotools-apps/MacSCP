import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SessionTab")
@MainActor
struct SessionTabTests {
    /// Builds a tab with the same collaborators `ContentView` hands it.
    /// Adjust only the initializer arguments if Core's signatures differ.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: none of these tests connects. A throwing
                // stub is the smallest value that satisfies the signature.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Attaches a live session to `tab`, the same shape
    /// `ContentView.startSession(in:with:)` builds — same helper as
    /// `CrossSessionTargetsTests.attachSession`, using `LocalFileSystem` as
    /// the "remote" side (a real `RemoteFileSystem` conformer that needs no
    /// network; none of these tests performs I/O through it).
    ///
    /// Every connect builds a NEW `BrowserSession`, so calling this twice is
    /// what "disconnect, connect again" looks like from this type's side.
    private func attachSession(to tab: SessionTab) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),

            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
    }

    /// A tab with no session is not connected, and shows the generic title
    /// rather than a stale name.
    @Test func aFreshTabIsNotConnectedAndUsesTheGenericTitle() {
        let tab = makeTab()

        #expect(tab.isConnected == false)
        #expect(tab.displayTitle.isEmpty == false)
        #expect(tab.displayTitle != "tabs.newConnection")
    }

    /// A named tab shows its own name.
    @Test func aNamedTabShowsItsName() {
        let tab = makeTab()
        tab.titleName = "prod-web"

        #expect(tab.displayTitle == "prod-web")
    }

    /// The confirmation suspends until answered, then reports the answer and
    /// clears the pending flag. A dialog that stayed "pending" after being
    /// answered would block every later connect on this tab.
    @Test func answeringTheConfirmationResumesItAndClearsThePendingFlag() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(await answer == true)
        #expect(tab.plaintextConfirmationPending == false)
    }

    /// A refusal is reported as `false`, and clears the pending flag exactly
    /// like an acceptance does. `ContentView`'s connector closure guards on
    /// exactly this value (`guard await box.tab.confirmPlaintext() else {
    /// throw … }`), so a `confirmPlaintext()` that came back `true` here
    /// would let a refused connect through.
    @Test func refusingTheConfirmationReportsFalse() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == false)
    }

    /// Resolving twice must not resume the continuation twice — that traps
    /// at runtime. The second call is a no-op by design.
    ///
    /// Caveat: the `#expect` below cannot observe a trap directly — a double
    /// resume aborts the whole test process (SIGABRT) rather than failing
    /// this assertion. A regression here would still fail the run, just not
    /// as a clean red result isolated to this test.
    @Test func resolvingTwiceIsHarmless() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == true)
    }

    /// Resolving without a pending prompt must not trap either — the UI can
    /// dismiss a sheet that was never asked for.
    ///
    /// Caveat: same as `resolvingTwiceIsHarmless` above — a regression to an
    /// unguarded unwrap would abort the process rather than fail the
    /// `#expect` below, which itself is nearly satisfied by construction
    /// (`confirmPlaintext()` is never called here, so the flag was never set
    /// `true` to begin with).
    @Test func resolvingWithNothingPendingIsHarmless() {
        let tab = makeTab()

        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(tab.plaintextConfirmationPending == false)
    }

    /// The audit flag must be resettable to false at the start of a connect:
    /// its whole purpose is that a previous connect's confirmation cannot
    /// leak into a later, unrelated connect's audit record.
    @Test func theConfirmationFlagCanBeSetAndCleared() {
        let tab = makeTab()

        tab.markPlaintextConfirmed()
        #expect(tab.pendingPlaintextConfirmation)

        tab.resetPendingPlaintextConfirmation()
        #expect(tab.pendingPlaintextConfirmation == false)
    }

    // MARK: - What the tab remembers about checksums

    /// The two panes' ledgers are separate: two file systems, and a path
    /// means nothing across them. A local `/report.csv` must never show the
    /// digest of a remote one.
    @Test func theTwoPanesRememberSeparately() throws {
        let tab = makeTab()
        attachSession(to: tab)
        let item = RemoteFileItem(name: "a", path: "/a", kind: .file, size: 1)
        let digest = try #require(
            FileChecksum.computedOnRemote(.sha256, hex: String(repeating: "b", count: 64)))

        tab.session?.remoteChecksums.record(.checksum(digest), for: item)

        #expect(tab.session?.localChecksums.value(for: item, algorithm: .sha256) == nil)
    }

    /// The lifetime it SHOULD have: a reconnect builds a fresh session, and
    /// with it a fresh ledger — nothing about the previous connection's
    /// bytes survives into the next one.
    @Test func reconnectingStartsWithNothingRemembered() throws {
        let tab = makeTab()
        attachSession(to: tab)
        let item = RemoteFileItem(name: "a", path: "/a", kind: .file, size: 1)
        let digest = try #require(
            FileChecksum.computedOnRemote(.sha256, hex: String(repeating: "c", count: 64)))
        tab.session?.remoteChecksums.record(.checksum(digest), for: item)

        attachSession(to: tab)

        #expect(tab.session?.remoteChecksums.value(for: item, algorithm: .sha256) == nil)
    }

    // MARK: - A hash that is still in flight when the connection changes

    /// A digest belongs to the connection it was computed over, and to no
    /// other (re-review N2).
    ///
    /// The hazard is real rather than theoretical: the info sheet's compute
    /// runs in an unstructured task that nothing cancels when the pane goes
    /// away, so a disconnect and reconnect can land underneath it. Whichever
    /// ledger the write RESOLVES to at that moment is the one it fills — and
    /// resolving it late means filling the new connection's, with a digest
    /// of another host's bytes. This is the same trap the liveness probe
    /// already names and defends against one screen away.
    ///
    /// So the binding names its session when it is made, and refuses to
    /// write once that session is gone. Reading is refused too: a stale
    /// binding must not show the new connection's values either.
    @Test func aChecksumThatLandsAfterAReconnectStaysOutOfTheNewSessionsLedger() throws {
        let tab = makeTab()
        attachSession(to: tab)
        let session = try #require(tab.session)
        let ledgerBinding = tab.checksumLedgerBinding(for: .remote, in: session)
        let item = RemoteFileItem(name: "big.iso", path: "/big.iso", kind: .file, size: 9)
        let digest = try #require(
            FileChecksum.computedOnRemote(.sha256, hex: String(repeating: "d", count: 64)))

        // The hash was started against `session`; the tab reconnects while
        // it is still running.
        attachSession(to: tab)

        // …and only now does the answer arrive and get written, exactly as
        // the funnel writes it.
        var landing = ledgerBinding.wrappedValue
        landing.record(.checksum(digest), for: item)
        ledgerBinding.wrappedValue = landing

        #expect(tab.session?.remoteChecksums.value(for: item, algorithm: .sha256) == nil)
        #expect(ledgerBinding.wrappedValue.value(for: item, algorithm: .sha256) == nil)
    }

    /// The positive half, over the same sequence: with no reconnect in the
    /// middle, the digest lands. Without this, a binding that refused every
    /// write would satisfy the test above.
    @Test func aChecksumWrittenThroughTheBindingLandsInItsOwnSessionsLedger() throws {
        let tab = makeTab()
        attachSession(to: tab)
        let session = try #require(tab.session)
        let ledgerBinding = tab.checksumLedgerBinding(for: .remote, in: session)
        let item = RemoteFileItem(name: "big.iso", path: "/big.iso", kind: .file, size: 9)
        let digest = try #require(
            FileChecksum.computedOnRemote(.sha256, hex: String(repeating: "e", count: 64)))

        var landing = ledgerBinding.wrappedValue
        landing.record(.checksum(digest), for: item)
        ledgerBinding.wrappedValue = landing

        #expect(tab.session?.remoteChecksums.value(for: item, algorithm: .sha256) == digest)
        #expect(ledgerBinding.wrappedValue.value(for: item, algorithm: .sha256) == digest)
    }

    /// The side is part of what the binding names: the local pane's binding
    /// writes the local ledger and leaves the remote one alone.
    @Test func eachSidesBindingWritesItsOwnLedger() throws {
        let tab = makeTab()
        attachSession(to: tab)
        let session = try #require(tab.session)
        let item = RemoteFileItem(name: "a", path: "/a", kind: .file, size: 1)
        let digest = try #require(
            FileChecksum.computedOnRemote(.sha256, hex: String(repeating: "f", count: 64)))

        let localBinding = tab.checksumLedgerBinding(for: .local, in: session)
        var landing = localBinding.wrappedValue
        landing.record(.checksum(digest), for: item)
        localBinding.wrappedValue = landing

        #expect(tab.session?.localChecksums.value(for: item, algorithm: .sha256) == digest)
        #expect(tab.session?.remoteChecksums.value(for: item, algorithm: .sha256) == nil)
    }

    // MARK: - Restoring a saved session (whole-phase re-review, items 1 + 2)
}
