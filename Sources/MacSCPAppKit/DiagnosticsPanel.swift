import SwiftUI
import macSCPCore

/// Explicitly started diagnostics. Settings control optional data collection;
/// presenting the sheet never authenticates, runs commands or contacts a service.
struct DiagnosticsPanel: View {
    let model: DiagnosticsViewModel
    private let onClose: () -> Void
    static let minimumWidth: CGFloat = 640

    init(model: DiagnosticsViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            controls
        }
        .padding(20)
        .frame(minWidth: Self.minimumWidth, idealWidth: 760, maxWidth: 860, minHeight: 600, maxHeight: 600)
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            L10n.text("diagnostics.title", "Connection diagnostics").font(.title2.bold())
            Text(model.name).font(.headline)
            if let endpoint = model.endpoint {
                Text(endpoint.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.steps.isEmpty && !model.isRunning {
                    VStack(spacing: 14) {
                        Image(systemName: "stethoscope").font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        L10n.text("diagnostics.ready", "Ready to run diagnostics").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 330)
                }
                ForEach(model.steps) { step in
                    if !(model.isConnectedSession && step.id == "session.access" && step.outcome == .ok) { row(step) }
                }
                if model.isRunning {
                    if model.isTestingThroughput { DiagnosticsThroughputView(progress: model.throughputProgress) }
                    else { measuring }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 520)
    }

    private var measuring: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let runningStepTitleKey = model.runningStepTitleKey {
                Text(String(format: L10n.string("diagnostics.running.step", "Measuring: %@"), L10n.string(runningStepTitleKey, runningStepTitleKey)))
            } else {
                L10n.text("diagnostics.running", "Measuring…")
            }
        }.font(.callout)
    }

    private func row(_ step: DiagnosticStep) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if step.id != "server.information" || step.outcome != .ok {
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DiagnosticsPresentation.title(of: step)).font(.headline)
                Text(badge(for: step))
                    .font(.caption.weight(.semibold)).foregroundStyle(outcomeColor(step.outcome))
                Spacer()
                Text(DiagnosticsPresentation.duration(of: step))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
              }
            }
            let reason = step.id.lowercased().contains("trace") && step.outcome.isPartialTrace
                ? "" : DiagnosticsPresentation.reason(of: step.outcome)
            if !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if !step.detail.isEmpty && !step.id.lowercased().contains("trace")
                && !(step.id == DiagnosticStepID.throughput && step.outcome == .ok) {
                Text(DiagnosticsPresentation.detail(of: step))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let table = step.table {
                if step.id.lowercased().contains("trace") {
                    ScrollView(.vertical) { grid(table) }
                        .frame(height: min(180, CGFloat(table.rows.count + 1) * 23))
                } else { grid(table) }
            }
        }
    }

    /// Flexible columns wrap text instead of creating horizontal scrollbars.
    private func grid(_ measured: DiagnosticTable) -> some View {
        Group {
            if measured.columns == DiagnosticThroughputColumn.all {
                DiagnosticsThroughputResults(table: measured)
            } else if measured.columns == ["diagnostics.system.field", "diagnostics.system.value"] {
                serverInformation(measured)
            } else if measured.columns.contains(DiagnosticNameColumn.name) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(measured.rows.enumerated()), id: \.offset) { _, cells in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(zip(measured.columns, cells).enumerated()), id: \.offset) { _, cell in
                                Text(DiagnosticsPresentation.cell(cell.1, column: cell.0))
                                    .foregroundStyle(cell.0 == DiagnosticNameColumn.address ? .primary : .secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(measured.columns.enumerated()), id: \.offset) { _, key in
                            Text(DiagnosticsPresentation.columnTitle(key)).fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(Array(measured.rows.enumerated()), id: \.offset) { _, cells in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(zip(measured.columns, cells).enumerated()), id: \.offset) { _, cell in
                                Text(DiagnosticsPresentation.cell(cell.1, column: cell.0))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serverInformation(_ measured: DiagnosticTable) -> some View {
        let systemFields: Set<String> = ["diagnostics.system.os", "diagnostics.system.kernel", "diagnostics.system.uptime",
            "diagnostics.system.load", "diagnostics.system.memory", "diagnostics.system.disk", "diagnostics.system.users"]
        let system = measured.rows.filter { $0.count >= 2 && systemFields.contains($0[0]) }
        let network = measured.rows.filter { $0.count >= 2 && !systemFields.contains($0[0]) && $0[1] != "—" }
        return HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 13) {
                L10n.text("diagnostics.section.system", "System").font(.headline)
                ForEach(Array(system.enumerated()), id: \.offset) { _, cells in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DiagnosticsPresentation.cell(cells[0], column: measured.columns[0]))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(cells[1]).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(cells[0] == "diagnostics.system.users"
                          ? L10n.string("diagnostics.users.help", "Active login users / login accounts; service accounts are excluded where identifiable.") : "")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !network.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    L10n.text("diagnostics.section.network", "Network").font(.headline)
                    ForEach(Array(network.enumerated()), id: \.offset) { _, cells in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DiagnosticsPresentation.cell(cells[0], column: measured.columns[0]))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(cells[1]).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            primaryAction
            if model.isConnectedSession {
                Button(L10n.string("diagnostics.transferTest", "Throughput test")) { model.runTransferTest() }
                    .buttonStyle(.polished)
                    .help(L10n.string("diagnostics.transferTest.notice", "Uploads a temporary file, reads it back and removes it. Your transfer limits apply."))
                    .disabled(model.isRunning || !model.canTestThroughput)
            }
            Spacer()
            if model.report != nil && !model.isRunning { copyControl }
            Button(L10n.string("common.close", "Close"), action: onClose)
                .buttonStyle(.polished).keyboardShortcut(.cancelAction)
        }
    }

    private var primaryAction: some View {
        Button(model.isRunning
               ? L10n.string("common.cancel", "Cancel")
               : L10n.string("diagnostics.run", "Run diagnostics")) {
            if model.isRunning { model.cancel() }
            else { model.scope = .complete; model.run() }
        }
        .buttonStyle(.polishedProminent)
        .keyboardShortcut(.defaultAction)
        .frame(minWidth: 140)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var copyControl: some View {
        Menu(L10n.string("diagnostics.copy", "Copy report")) {
            Button(L10n.string("diagnostics.copy.plainText", "Plain text")) { model.copyPlainText() }
            Button(L10n.string("diagnostics.copy.markdown", "Markdown")) { model.copyMarkdown() }
        }.disabled(model.copyableReport == nil)
    }

    private func badge(for step: DiagnosticStep) -> String {
        if step.id.lowercased().contains("trace"), step.outcome.isPartialTrace {
            return L10n.string("diagnostics.trace.notReached", "Destination not reached")
        }
        return DiagnosticsPresentation.badge(for: step.outcome)
    }

    private func outcomeColor(_ outcome: DiagnosticOutcome) -> Color {
        switch outcome {
        case .ok: DesignTokens.statusPhosphor
        case .failed: DesignTokens.statusLost
        case .timedOut, .partial: .orange
        case .unavailable, .skipped, .notStarted: .secondary
        }
    }
}

private extension DiagnosticOutcome {
    var isPartialTrace: Bool { if case .partial = self { true } else { false } }
}
