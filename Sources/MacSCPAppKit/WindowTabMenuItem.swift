import SwiftUI

/// A window-local snapshot, shared by menu selection and tab cycling.
struct WindowTabMenuItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let index: Int
    let isSelected: Bool

    var shortcut: KeyboardShortcut? {
        guard (0..<9).contains(index) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }
}
