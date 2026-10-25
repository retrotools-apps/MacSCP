import Foundation
import macSCPCore

/// The one owner of a tab's teardown order (Quit Teardown plan, Task 1).
///
/// **Why this is a type of its own.** The order `cancelAll` →
/// `editManager.stopAll` → `terminal.shutdown` → `remote.disconnect` is an
/// architecture invariant (`CLAUDE.md`), and it used to be spelled inside
/// `ContentView.teardown(_:reason:)` — a method on a SwiftUI view. Every
/// caller that could reach it therefore had to have a `ContentView`, and the
/// app's quit does not: `AppDelegate` has no view, and a tab parked for a
/// window that never appeared belongs to no view either. The alternative was
/// a second spelling of the four stages on the quit path, which is exactly
/// the second copy this project's rules exist to prevent, and would be the
/// copy that goes stale. So the sequence moved out to here, where a view is
/// not a precondition for running it, and `ContentView.teardown(_:reason:)`
/// became a call into this function.
///
/// `QuitSequenceTests.onlyTheOneOwnerNamesTheTeardownStages` holds that: the
/// two `TeardownStage` cases are named in exactly two files under `Sources/`
/// — `TeardownStage.swift`, which declares them, and this one, which runs
/// them.
///
/// **What did NOT move.** `ContentView.teardown(_:reason:)` still calls
/// `stopDiagnostics(of:)` after this function returns, because that reads
/// the WINDOW's `DiagnosticsPresenter` (`ContentView.diagnostics`, a
/// `@State` value) and nothing on the tab can reach it. A parked tab
/// therefore has no diagnosis to stop — it is in no window, so no window's
/// panel was ever opened for it.
@MainActor
enum TabTeardown {
    /// Tab-local teardown, in the invariant order: bridge dismiss →
    /// `cancelAll` → `editManager.stopAll` → `terminal.shutdown` →
    /// `remote.disconnect`. Other connections stay open; only incoming jobs
    /// targeting this destination are cancelled on their source queues.
    ///
    /// `reason` (connection-liveness plan, Task 8; required — see
    /// `CancelReason`'s own doc comment for why a `Bool` default was
    /// rejected) forwards straight into `cancelAll(reason:)`: the ONE call
    /// site that passes `.connectionLost` is
    /// `ContentView.handleLivenessGiveUp(_:)`, so the running transfer fails
    /// with a "connection lost" reason and every queued item is marked and
    /// kept — every OTHER one passes `.userRequested` (a deliberate
    /// disconnect, not a drop), which keeps the plain `.cancelled` this
    /// sequence always produced. The order itself (`cancelAll` first,
    /// everything else after) is unchanged by this parameter — it only
    /// changes what `cancelAll` writes onto the queue's own items, not when
    /// it runs.
    ///
    /// **What is bounded here, and what is not.** Three of the four stages
    /// carry a wall-clock bound; the first one does not.
    ///
    /// - `editManager.stopAll()` and `terminal.shutdown()` are bounded HERE,
    ///   through `TeardownStage.runBounded` — see that type for the
    ///   measurements behind the five seconds and for which of the two was
    ///   measured to need it (`terminal.shutdown()`; it did not return
    ///   inside a 20-second watchdog against a frozen peer, in three runs
    ///   out of three).
    /// - `remote.disconnect()` carries its own bound INSIDE
    ///   `CitadelFileSystem.disconnect()` (`7ac7f7e`) and is deliberately
    ///   not wrapped again: measured against that same frozen peer it
    ///   returned in 5.002063 s / 5.304208 s / 5.333977 s.
    /// - `transferQueue.cancelAll(reason:)` is **not bounded** — neither
    ///   here nor inside itself. It was wrapped for one commit (`eed1c8a`)
    ///   and the maintainer removed the wrapper on 2026-08-28, because the
    ///   bound was measured to catch nothing and to cost something. Against
    ///   the frozen peer, with an open PTY shell AND an 8 MB download
    ///   running at the moment of the freeze, `cancelAll` returned in
    ///   0.004462916 s / 0.004904750 s / 0.005558917 s — three runs out of
    ///   three, none of them near a bound. What the wrapper cost is
    ///   visible right below: `BoundedClose` runs its operation in a
    ///   separate task, so wrapping this call makes this function suspend
    ///   BEFORE the queue is swept, and a transfer that fails completely
    ///   inside that one extra main-actor turn then keeps its own error
    ///   text instead of reading "Connection lost." (one that merely starts
    ///   is still marked correctly). Swift has no version with both: an
    ///   async function cannot be run synchronously up to its first
    ///   suspension point inside another task.
    ///
    /// **So the guarantee this function can make is narrower than "it always
    /// reaches its end".** The incoming-copy cancellation barrier is also
    /// unbounded. Once both this tab's queue and its incoming copies settle,
    /// the remaining connection-owning stages reach their end within roughly
    /// `2 × TeardownStage.boundSeconds + CitadelFileSystem
    /// .sftpCloseBoundSeconds`. `cancelAll` itself has no such ceiling: it
    /// awaits every running transfer to unwind (step 3) and is documented as
    /// able to block on an open decider prompt — which is why
    /// `conflictBridge.cancelOpenPrompt()` runs first, and why the
    /// measurement above, not an argument, is what says this is safe today.
    /// If a teardown is ever seen to hang before the first stage bound can
    /// fire, this is the stage to measure first. It is also the reason the
    /// app's quit puts its own `QuitWatchdog.bound` around the whole chain
    /// rather than trusting this one to end.
    ///
    /// A bound around this whole function instead of one per stage was
    /// considered and rejected by the maintainer: it would abandon the
    /// invariant order wherever it stood and could not name the stage that
    /// hung.
    ///
    /// **This function does not check `Task.isCancelled`.** A teardown that
    /// stopped half way would leave a shell open on a connection whose queue
    /// had already been swept — worse than either end state. The quit's
    /// watchdog cancels the chain BETWEEN tabs and windows, never inside
    /// one; see `QuitWatchdog.bound`.
    static func run(_ tab: SessionTab, reason: CancelReason) async {
        if tab.isDisconnecting {
            // Every caller must await the connection owner's cleanup, not merely
            // observe that another caller started it. Cancellation never abandons it.
            await withCheckedContinuation { tab.disconnectionWaiters.append($0) }
            return
        }
        tab.isDisconnecting = true
        defer {
            tab.isDisconnecting = false
            let waiters = tab.disconnectionWaiters
            tab.disconnectionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let pair = tab.remotePair
        let peers = [pair?.left, pair?.right].compactMap { $0 }
        pair?.detach()
        tab.editErrorMessage = nil
        tab.remoteTransferErrorMessage = nil
        if let session = tab.session {
            // MUST run before `cancelAll(reason:)`: an open conflict sheet would
            // otherwise keep the decider prompt open, which `cancelAll`
            // (documented) hangs on until it's answered — deadlock on disconnect.
            tab.conflictBridge.cancelOpenPrompt()
            // Called directly, NOT through `TeardownStage.runBounded` (see
            // this function's doc comment): a bound would put a suspension
            // point in front of the sweep, and the queue sweep running in
            // this function's own first main-actor turn is worth more than a
            // bound that three frozen-peer runs measured at under six
            // milliseconds.
            await tab.transferQueue.cancelAll(reason: reason)
            // Close built-in document readers and settle saves before the
            // transport is disconnected. Tab switches do not run this path.
            await tab.fileWindows.closeAll()
            // Incoming copies are owned by their source tabs, including after
            // unlinking the presentation. Settle them before disconnecting, but
            // preserve the immediate cancellation of this tab's own work above.
            var visited = Set<UUID>()
            for source in TabRegistry.shared.allTabs() + peers where source !== tab && visited.insert(source.id).inserted {
                await source.transferQueue.cancelTransfers(to: tab.id, cancelConflict: {
                    source.conflictBridge.cancelOpenPrompt()
                })
            }
            // Binding order (M5e/T4 plan): AFTER `cancelAll` (any in-flight
            // edit download/upload has already been cancelled/settled by the
            // queue, so `stopAll` isn't racing a still-running transfer) and
            // BEFORE `terminal.shutdown`/`disconnect` (teardown proceeds
            // outward from the queue to the connection).
            await TeardownStage.stopEditWatchers.runBounded { [editManager = session.editManager] in
                await editManager.stopAll()
            }
            await TeardownStage.shutDownTerminal.runBounded { [terminal = session.terminal] in
                await terminal.shutdown()
            }
            await session.remote.disconnect()
            // The close report ends with the connection it described (fix
            // round 1 of the lost-connection cause work, review Minor 8).
            // `CitadelFileSystem.disconnect()` reports both of its hops
            // before returning, so the `by=app` lines are already written
            // by the time this runs; what it refuses is a close arriving
            // later — from a channel that had not finished closing — which
            // would name a tab whose session is gone. Observation only:
            // nothing here owns or closes anything.
            (session.remoteFS as? TransportCloseReporting)?.stopReportingTransportClose()
            // Audit recorder teardown (M9b/T3): only present for a stored
            // session (`attachAuditRecorder` never runs for an ad-hoc
            // connect), so this is a no-op otherwise. `recordDisconnected()`
            // FIRST, then release the recorder and BOTH sinks it wired.
            //
            // This is the `disconnected` row the app's quit exists to
            // reach (`docs/BACKLOG.md`, "Quit tears down nothing"): before
            // the quit ran a teardown at all, a session the user quit out
            // of never got one.
            if let recorder = tab.auditRecorder {
                recorder.recordDisconnected()
                tab.auditRecorder = nil
                tab.transferQueue.auditSink = nil
                session.remote.auditSink = nil
            }
        }
        let form = tab.connectionViewModel
        // `clearRetainedSecrets()` (not the narrower `clearPassword()`):
        // this tab's `connectionViewModel` survives past this teardown, so
        // its `lastConnectedConfig` (the external-terminal launcher's own
        // copy of the same secret) must be forgotten here too, or it would
        // keep the first connect's plaintext password in memory across
        // every later disconnect/reconnect in this tab (review finding,
        // M11d fix round 1).
        form.clearRetainedSecrets()
        form.authChoice = .password
        form.keyPath = ""
        // Reset any pending edit context: a stale `.edit(sessionID:)`
        // surviving into the next Save would overwrite the wrong stored
        // session (M5f/T4 review).
        form.exitEditMode()
        tab.session = nil
        tab.activeStoredSessionID = nil
        tab.titleName = nil
        // Stale liveness (connection-liveness plan, Task 4, fix round 2).
        // Every route into this function is a deliberate "leave this
        // connection" — `ContentView.teardown(_:reason:)`'s own doc comment
        // enumerates its callers, and the app's quit sweep is the one route
        // that does not come through a view at all. There is no connection
        // left to describe afterward, so a dot left reading
        // `.degraded`/`.lost` from before this call would be describing a
        // session that is no longer there.
        //
        // The ONE exception is `ContentView.handleLivenessGiveUp(_:)`, which
        // writes `.lost` AFTER its call to `teardown` returns, precisely so
        // that write is not the one this line clears.
        tab.liveness = nil
        // Same rule, same sentence, for the lost-connection record (Task
        // 7): every route in is leaving this connection on purpose, and a
        // record of a DROP would be describing something that did not
        // happen. `handleLivenessGiveUp` is the same one exception it is
        // for `liveness` — it writes this afterwards, deliberately after
        // this line has run.
        tab.lostConnection = nil
        // And the third fact describing a connection that is over
        // (failed-connect surface plan, review round 1): a FAILED ATTEMPT.
        // Measured before this line existed: on a window with one tab —
        // the normal case at launch — typing a host, timing out and
        // pressing "Close" ran `performClose`, which tears the tab down
        // but does NOT remove the last tab, and the failed-connect surface
        // stayed up with all four buttons while the window shrank around
        // it. A button named "Close" that visibly does nothing is the
        // exact complaint this whole surface was written to answer.
        //
        // The sibling surface never had this defect because it hangs off
        // `liveness == .lost`, which this function's own `tab.liveness`
        // reset clears; this one hangs off a property teardown did not
        // touch. Same sentence as the other two resets, therefore: every
        // route in is leaving this connection on purpose, so a record of an
        // attempt that failed is describing something the tab has been
        // taken past.
        tab.connectFailure = nil
    }
}
