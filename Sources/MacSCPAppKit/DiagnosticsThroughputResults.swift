import SwiftUI
import macSCPCore

/// Show the measured rates prominently; exact byte counts remain in exports.
struct DiagnosticsThroughputResults: View {
    let table: DiagnosticTable

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                if row.count == DiagnosticThroughputColumn.all.count {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(DiagnosticsPresentation.cell(row[0], column: DiagnosticThroughputColumn.direction))
                            .foregroundStyle(.secondary)
                        Text(row[3]).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(DesignTokens.remoteBlue)
                        Text(Self.secondsText(row[2])).foregroundStyle(.secondary)
                        if row[4] != DiagnosticThroughputColumn.none {
                            Text(DiagnosticsPresentation.columnTitle(DiagnosticThroughputColumn.limit) + ": " + row[4])
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                }
            }
        }.padding(.vertical, 14)
    }

    static func secondsText(_ milliseconds: String) -> String {
        guard milliseconds.hasSuffix(" ms"), let value = Double(milliseconds.dropLast(3)) else { return milliseconds }
        return String(format: "%.1f s", locale: .current, value / 1000)
    }
}
