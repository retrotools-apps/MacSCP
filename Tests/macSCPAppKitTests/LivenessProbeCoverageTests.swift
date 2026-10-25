import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the property `LivenessProbeMountGuardTests` cannot: WHICH tabs
/// `LivenessProbeCoverage.tabsToProbe` selects, not just that
/// `ContentView.splitLayout` asks it. A source-text scan can prove the view
/// calls this function; only a test that actually calls it and reads the
/// result can prove the function itself covers every connected tab rather
/// than, say, only the active one.
@Suite("Liveness probe coverage")
@MainActor
struct LivenessProbeCoverageTests {
    /// Same shape as `SessionTabTests.makeTab()`/`CrossSessionTargetsTests
    /// .makeTab()`: the collaborators `ContentView` hands a real tab.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Same shape as `SessionTabTests.attachSession(to:)`: a live session
    /// using `LocalFileSystem` as the "remote" side, since none of these
    /// tests performs I/O through it.
    private func attachSession(to tab: SessionTab) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
    }

    @Test func everyConnectedTabIsIncludedRegardlessOfWhichIsActive() {
        let connectedA = makeTab()
        attachSession(to: connectedA)
        let unconnected = makeTab()
        let connectedB = makeTab()
        attachSession(to: connectedB)

        // Order matters here only insofar as both connected tabs must
        // survive the filter — `activeTabID` never enters this function's
        // signature at all, which is the point: coverage cannot depend on
        // which tab is active because nothing here even knows.
        let probed = LivenessProbeCoverage.tabsToProbe(from: [connectedA, unconnected, connectedB])

        #expect(probed.map(\.id) == [connectedA.id, connectedB.id])
    }

    @Test func anUnconnectedTabIsExcluded() {
        let tab = makeTab()
        #expect(LivenessProbeCoverage.tabsToProbe(from: [tab]).isEmpty)
    }

    @Test func allConnectedSavedSessionsStayVisibleRegardlessOfSelection() {
        let a = makeTab()
        let b = makeTab()
        let disconnected = makeTab()
        a.activeStoredSessionID = UUID()
        b.activeStoredSessionID = UUID()
        disconnected.activeStoredSessionID = UUID()
        attachSession(to: a)
        attachSession(to: b)
        let tabs = TabsViewModel(initial: a)
        tabs.addTab(b)
        tabs.addTab(disconnected)
        let expected = Set([a.activeStoredSessionID!, b.activeStoredSessionID!])
        #expect(SessionSidebarConnections.connectedSessionIDs(in: tabs.tabs) == expected)
        tabs.activate(a.id)
        #expect(SessionSidebarConnections.connectedSessionIDs(in: tabs.tabs) == expected)
        tabs.activate(b.id)
        #expect(SessionSidebarConnections.connectedSessionIDs(in: tabs.tabs) == expected)
        a.session = nil
        #expect(SessionSidebarConnections.connectedSessionIDs(in: tabs.tabs) == Set([b.activeStoredSessionID!]))
    }

    @Test func duplicateTabsShareOneIndicatorAndUnsavedTabsHaveNoSidebarRow() {
        let a = makeTab()
        let duplicate = makeTab()
        let unsaved = makeTab()
        let id = UUID()
        a.activeStoredSessionID = id
        duplicate.activeStoredSessionID = id
        for tab in [a, duplicate, unsaved] { attachSession(to: tab) }
        #expect(SessionSidebarConnections.connectedSessionIDs(in: [a, duplicate, unsaved]) == Set([id]))
        a.session = nil
        #expect(SessionSidebarConnections.connectedSessionIDs(in: [a, duplicate, unsaved]) == Set([id]))
        duplicate.session = nil
        #expect(SessionSidebarConnections.connectedSessionIDs(in: [a, duplicate, unsaved]).isEmpty)
    }

    @Test func anEmptyTabListProducesAnEmptyResult() {
        #expect(LivenessProbeCoverage.tabsToProbe(from: []).isEmpty)
    }
}
