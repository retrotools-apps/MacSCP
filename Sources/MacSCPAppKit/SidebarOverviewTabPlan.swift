import Foundation

/// A connected tab owns its live browser/console surface. Selecting a saved
/// connection in the sidebar must therefore open an idle tab for the
/// overview instead of changing state that the connected surface cannot show.
enum SidebarOverviewTabPlan {
    static func needsNewTab(selectedSessionID: UUID?, activeTabConnected: Bool) -> Bool {
        selectedSessionID != nil && activeTabConnected
    }
}
