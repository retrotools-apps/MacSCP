import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("MenuBarStatusModel")
@MainActor
struct MenuBarStatusModelTests {
    @Test func stoppingConnectionsRoutesToEveryOpenWindowOnceAndRejectsReentry() async {
        let model = MenuBarStatusModel()
        let first = WindowID(), second = WindowID(), closed = WindowID()
        var calls: [WindowID] = []
        for window in [first, second, closed] {
            model.record(tabs: [makeTab()], from: window)
            model.registerConnectionStop(from: window) {
                calls.append(window)
                #expect(model.stoppingConnections)
                await model.stopAllConnections()
            }
        }
        model.clearIfPublished(by: closed)
        await model.stopAllConnections()
        #expect(Set(calls) == [first, second])
        #expect(calls.count == 2)
        #expect(!model.stoppingConnections)
    }

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

    /// With no tabs the status item must read idle and count zero — not
    /// crash on an empty aggregation.
    ///
    /// Caveat: `Array.contains`/`Array.filter(_:).count` over an empty
    /// `tabs` are `false`/`0` regardless of the closure passed to them, so
    /// this only catches a hard-coded wrong default (e.g. returning `true`
    /// or a nonzero constant), not a broken aggregation rule. The actual
    /// per-tab logic is covered by `disconnectedTabsDoNotCount` and
    /// `tabsWithoutRunningTransfersLeaveTheIconIdle` below.
    @Test func anEmptyModelIsIdleAndCountsNothing() {
        let model = MenuBarStatusModel()

        #expect(model.anyTransferActive == false)
        #expect(model.connectedCount == 0)
    }

    /// Disconnected tabs must not be counted: the header counter says how
    /// many sessions are live, not how many tabs are open.
    @Test func disconnectedTabsDoNotCount() {
        let model = MenuBarStatusModel()
        model.publish(
            tabs: [makeTab(), makeTab()], from: WindowID(),
            focusTab: { _ in }, showMainWindow: {})

        #expect(model.connectedCount == 0)
    }

    /// An idle tab must not contribute a running transfer to the aggregate.
    @Test func tabsWithoutRunningTransfersLeaveTheAggregateIdle() {
        let model = MenuBarStatusModel()
        model.publish(
            tabs: [makeTab()], from: WindowID(),
            focusTab: { _ in }, showMainWindow: {})

        #expect(model.anyTransferActive == false)
    }

    /// The closures must be callable defaults, so a status item built before
    /// `ContentView` wires them does not trap when clicked.
    @Test func theDefaultClosuresAreSafeToCall() {
        let model = MenuBarStatusModel()

        model.showMainWindow()
        model.focusTab(UUID())
    }
}
