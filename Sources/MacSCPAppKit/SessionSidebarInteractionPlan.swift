import macSCPCore

/// A saved-session editor locks this window's session navigation until Save
/// or Back ends edit mode, even if another open tab is selected meanwhile.
/// Transfers do not lock navigation; active connection attempts still do.
enum SessionSidebarInteractionPlan {
    static func isDisabled(
        formModes: [ConnectionViewModel.FormMode], isConnecting: Bool, isReconnecting: Bool
    ) -> Bool {
        if formModes.contains(where: { if case .edit = $0 { return true }; return false }) { return true }
        return isConnecting || isReconnecting
    }
}
