/// Selecting an unconnected tab reveals the session picker. Switching between
/// connected tabs preserves the user's explicit sidebar visibility choice.
enum SidebarVisibilityPolicy {
    static func selectingTab(isVisible: Bool, hasSession: Bool) -> Bool {
        isVisible || !hasSession
    }
}
