import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Main window presentation")
@MainActor
struct MainWindowPresentationTests {
    private final class Window {}

    @MainActor private final class Probe {
        var jobs: [@MainActor () -> Void] = []
        var revealed: [Window] = []
        var opens = 0

        func drain() {
            let pending = jobs
            jobs = []
            for action in pending { action() }
        }

        func coordinator() -> WindowPresentation<Window> {
            WindowPresentation(reveal: { self.revealed.append($0) }, schedule: { self.jobs.append($0) })
        }
    }

    @Test func launchWaitsForTheWindowAndRaisesItOnlyOnce() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        coordinator.setOpener { probe.opens += 1 }
        coordinator.foregroundAtLaunch()
        probe.drain()
        #expect(probe.opens == 0)
        #expect(probe.revealed.isEmpty)
        let window = Window()
        coordinator.register(window)
        coordinator.register(window)
        #expect(probe.revealed.isEmpty)
        probe.drain()
        #expect(probe.revealed.count == 1)
        #expect(probe.revealed.first === window)
        coordinator.register(window)
        probe.drain()
        #expect(probe.revealed.count == 1)
    }

    @Test func showRestoresTheLastFocusedWindowAfterHide() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        let first = Window(), second = Window()
        coordinator.register(first)
        coordinator.register(second)
        coordinator.didBecomeKey(first)
        coordinator.didHide()
        coordinator.show()
        probe.drain()
        #expect(probe.revealed.last === first)
        coordinator.show(preferred: second)
        probe.drain()
        #expect(probe.revealed.last === second)
    }

    @Test func closeBeforeScheduledShowUsesTheRemainingWindow() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        let first = Window(), closed = Window()
        coordinator.register(first)
        coordinator.register(closed)
        coordinator.show(preferred: closed)
        coordinator.unregister(closed)
        probe.drain()
        #expect(probe.revealed.last === first)
    }

    @Test func showWithoutWindowsOpensOneNewWindowEvenWithoutStatusPublication() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        coordinator.show()
        coordinator.setOpener { probe.opens += 1 }
        coordinator.show()
        #expect(probe.opens == 1)
        let newWindow = Window()
        coordinator.register(newWindow)
        probe.drain()
        #expect(probe.revealed.last === newWindow)
    }

    @Test func deliberateHideCancelsPendingLaunchActivation() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        let window = Window()
        coordinator.foregroundAtLaunch()
        coordinator.register(window)
        coordinator.didHide()
        probe.drain()
        coordinator.register(window)
        probe.drain()
        #expect(probe.revealed.isEmpty)
        coordinator.show()
        probe.drain()
        #expect(probe.revealed.last === window)
    }

    @Test func closingTheLastWindowNeverResurrectsIt() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        let closed = Window()
        coordinator.register(closed)
        coordinator.didBecomeKey(closed)
        coordinator.show()
        coordinator.unregister(closed)
        coordinator.setOpener { probe.opens += 1 }
        probe.drain()
        #expect(probe.opens == 1)
        #expect(probe.revealed.isEmpty)
        let replacement = Window()
        coordinator.register(replacement)
        probe.drain()
        #expect(probe.revealed.last === replacement)
    }

    @Test func registryDoesNotKeepClosedWindowsAlive() {
        let probe = Probe()
        let coordinator = probe.coordinator()
        weak var weakWindow: Window?
        do {
            let window = Window()
            weakWindow = window
            coordinator.register(window)
            coordinator.didBecomeKey(window)
        }
        #expect(weakWindow == nil)
        coordinator.setOpener { probe.opens += 1 }
        coordinator.show()
        #expect(probe.opens == 1)
    }

    @Test func appLifecycleAndStatusItemUseTheIndependentWindowPresenter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try SourceCorpus.code(of: root.appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift"))
        let menu = try SourceCorpus.code(of: root.appendingPathComponent("Sources/MacSCPAppKit/MenuBarController.swift"))
        let presenter = try SourceCorpus.code(of: root.appendingPathComponent("Sources/MacSCPAppKit/MainWindowPresentation.swift"))
        #expect(app.contains("func applicationDidFinishLaunching("))
        #expect(app.contains("MainWindowPresentation.shared.foregroundAtLaunch()"))
        #expect(app.contains("func applicationShouldHandleReopen("))
        #expect(app.contains("MainWindowPresentation.shared.show()"))
        let host = try #require(app.range(of: "MainWindowPresentationHost {"))
        let credentials = try #require(app.range(of: "CredentialStartupView {"))
        #expect(host.lowerBound < credentials.lowerBound)
        #expect(menu.contains("@objc private func showMainWindow()"))
        #expect(menu.contains("MainWindowPresentation.shared.show()"))
        #expect(!menu.contains("model.showMainWindow()"))
        #expect(presenter.contains("app.unhide(nil)"))
        #expect(presenter.contains("window.deminiaturize(nil)"))
        #expect(presenter.contains("window.makeKeyAndOrderFront(nil)"))
    }
}
