import SwiftUI

/// A shared visual boundary for the overview's configuration, inventory and history.
struct SessionOverviewSectionHeading: View {
    let title: String
    var note: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).textCase(.uppercase)
                .foregroundStyle(DesignTokens.ink)
            Spacer(minLength: 8)
            if let note {
                Text(note).font(.caption).foregroundStyle(DesignTokens.inkSecondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(DesignTokens.hairline.opacity(0.35))
        .overlay(alignment: .bottom) { DesignTokens.hairline.frame(height: 1) }
    }
}
