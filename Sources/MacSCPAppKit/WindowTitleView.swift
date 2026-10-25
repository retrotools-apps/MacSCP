import SwiftUI

/// The native toolbar's leading title item; the window keeps its textual title for
/// the Window menu, accessibility, and toolbar-hidden presentations.
@MainActor
struct WindowTitleView: View {
    let title: TabTitle
    // Decode the existing application artwork once, not on every tab update.
    private static let icon = ApplicationIcon.load()

    var body: some View {
        HStack(spacing: 7) {
            if let icon = Self.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            Text(title.windowTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 260, alignment: .leading)
        .help(title.windowTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.windowTitle)
    }
}
