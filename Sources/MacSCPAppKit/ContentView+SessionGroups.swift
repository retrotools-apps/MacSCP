import macSCPCore

extension ContentView {
    func showSessionGroup(_ group: StoredGroup) {
        guard !sidebarInteractionsDisabled, let tab = formTarget() else { return }
        overviewSessionID = nil
        tab.restoredSessionID = nil
        tab.overviewGroupID = group.id
    }

    func connectFromGroupCard(_ stored: StoredSession) {
        activeTab.overviewGroupID = nil
        overviewSessionID = stored.id
        activeTab.restoredSessionID = nil
        connectFromSidebar(stored)
    }
}
