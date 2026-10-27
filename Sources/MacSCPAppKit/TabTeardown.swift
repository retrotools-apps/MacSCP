import Foundation
import macSCPCore

@MainActor
enum TabTeardown {
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
            await TeardownStage.stopEditWatchers.runBounded { [editManager = session.editManager] in
                await editManager.stopAll()
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
