import SwiftUI
import macSCPCore

/// A speed-test dial driven exclusively by real transfer-engine samples.
struct DiagnosticsThroughputView: View {
    let progress: DiagnosticThroughputProgress?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875).stroke(.quaternary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * (progress?.fraction ?? 0))
                    .stroke(DesignTokens.remoteBlue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: progress?.fraction)
                VStack(spacing: 6) {
                    Text(isTransferring ? progress.map { String(format: "%.1f", $0.megabitsPerSecond) } ?? "—" : "—")
                        .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("Mbit/s").font(.caption).foregroundStyle(.secondary)
                }.rotationEffect(.degrees(-90))
            }.rotationEffect(.degrees(90)).frame(width: 170, height: 170)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if isTransferring {
                    Image(systemName: progress?.phase == .upload ? "arrow.up" : "arrow.down")
                        .foregroundStyle(DesignTokens.remoteBlue).accessibilityHidden(true)
                    Text(phaseTitle).fontWeight(.medium)
                    Text(progress.map { "\(Int($0.fraction * 100)) %" } ?? "").monospacedDigit()
                } else {
                    Text(phaseTitle)
                }
            }
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 310)
        .accessibilityElement(children: .combine)
    }

    private var isTransferring: Bool { progress?.phase == .upload || progress?.phase == .download }

    private var phaseTitle: String {
        switch progress?.phase {
        case .upload: L10n.string("diagnostics.speed.upload", "Upload")
        case .download: L10n.string("diagnostics.speed.download", "Download")
        case .cleanup: L10n.string("diagnostics.speed.cleanup", "Removing test file…")
        default: L10n.string("diagnostics.speed.preparing", "Preparing test…")
        }
    }
}
