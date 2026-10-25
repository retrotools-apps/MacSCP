import AppKit
import SwiftUI
import Testing
import macSCPCore
@testable import MacSCPAppKit

@Suite("Diagnostics panel layout", .serialized)
@MainActor
struct DiagnosticsPanelRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func bothModesRenderWithoutStartingNetworkWork(scheme: ColorScheme, connected: Bool) async throws {
        let model = DiagnosticsViewModel(name: "Production server", isConnectedSession: connected,
            networkEndpoint: Endpoint(host: "gateway.example.com", port: 443),
            endpoint: Endpoint(host: "server.example.com", port: 22), runner: { _, _ in
                Issue.record("Rendering must not start a diagnostic")
                return DiagnosticReport(endpoint: nil, steps: [], appVersion: "test")
            })
        let renderer = ImageRenderer(content: DiagnosticsPanel(model: model, onClose: {})
            .environment(\.colorScheme, scheme))
        renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.isValid)
        #expect(image.size.width <= 760)
        #expect(image.size.height > 0)
        #expect(model.runTask == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func populatedReportsStayWithinThePanel(scheme: ColorScheme, connected: Bool) async throws {
        let rows = connected ? [
            ["diagnostics.system.os", "Debian GNU/Linux 13 (trixie)"],
            ["diagnostics.system.kernel", "Linux 6.12.111+deb13-amd64"],
            ["diagnostics.system.uptime", "18d 22h 3m"],
            ["diagnostics.system.load", "0.00 0.00 0.00"],
            ["diagnostics.system.memory", "3.8 / 8.0 GiB"],
            ["diagnostics.system.disk", "50.0 / 100.0 GiB"],
            ["diagnostics.system.users", "1 / 7"],
            ["eno1", "192.0.2.10\n2001:db8::10"],
        ] : [["192.0.2.10", "very-long-reverse-dns-name.example.production.infrastructure.example.org", DiagnosticNameColumn.resolvesBack]]
        let table = DiagnosticTable(columns: connected
            ? ["diagnostics.system.field", "diagnostics.system.value"]
            : DiagnosticNameColumn.all, rows: rows)
        let measured = DiagnosticStepTimer(id: connected ? "server.information" : DiagnosticStepID.resolve,
            titleKey: connected ? "diagnostics.step.serverInformation" : DiagnosticStepID.titleKey(for: DiagnosticStepID.resolve))
            .finish(.ok, "", table: table)
        let trace = DiagnosticStepTimer(id: DiagnosticStepID.trace, titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.trace))
            .finish(.ok, "", table: DiagnosticTable(columns: DiagnosticTraceColumn.all,
                rows: (1...30).map { [String($0), "192.0.2.\($0)", "5.2 ms", DiagnosticTraceColumn.answered] }))
        let steps = connected ? [DiagnosticStepTimer(id: "session.access", titleKey: "diagnostics.step.sessionAccess").finish(.ok, ""), measured]
                              : [measured, trace]
        let model = DiagnosticsViewModel(name: "Production server", isConnectedSession: connected,
            endpoint: Endpoint(host: "server.example.com", port: 22), runner: { _, observer in
                for step in steps { await observer.onStep(step) }
                return DiagnosticReport(endpoint: nil, steps: steps, appVersion: "test")
            })
        model.run()
        await model.runTask?.value
        #expect(model.report != nil)
        let renderer = ImageRenderer(content: DiagnosticsPanel(model: model, onClose: {})
            .environment(\.colorScheme, scheme))
        renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 760)
        #expect(image.size.height > 0)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func throughputResultsRenderRatesWithinThePanel(scheme: ColorScheme) throws {
        let table = DiagnosticTable(columns: DiagnosticThroughputColumn.all, rows: [
            [DiagnosticThroughputColumn.up, "2097152", "3000.0 ms", "5.6 Mbit/s", DiagnosticThroughputColumn.none],
            [DiagnosticThroughputColumn.down, "2097152", "1000.0 ms", "16.8 Mbit/s", "64.0 Mbit/s"]
        ])
        let renderer = ImageRenderer(content: DiagnosticsThroughputResults(table: table)
            .environment(\.colorScheme, scheme).padding(20))
        renderer.proposedSize = ProposedViewSize(width: 700, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.isValid)
        #expect(image.size.width <= 700)
        #expect(image.size.height < 200)
        #expect(DiagnosticsThroughputResults.secondsText("3000.0 ms").hasSuffix(" s"))
        #expect(DiagnosticsThroughputResults.secondsText("unavailable") == "unavailable")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func speedDialRendersActualSample(scheme: ColorScheme) throws {
        let sample = DiagnosticThroughputProgress(phase: .download, bytes: 12_000_000, total: 16_000_000, elapsed: 2)
        let renderer = ImageRenderer(content: DiagnosticsThroughputView(progress: sample)
            .environment(\.colorScheme, scheme).padding(20)
            .background(scheme == .dark ? Color.black : .white))
        renderer.proposedSize = ProposedViewSize(width: 700, height: 380)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 700)
        #expect(sample.megabitsPerSecond == 48)
    }
}
