import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("Sidebar overview tab plan")
struct SidebarOverviewTabPlanTests {
    @Test func selectingAConnectionFromAConnectedTabNeedsANewTab() {
        #expect(SidebarOverviewTabPlan.needsNewTab(
            selectedSessionID: UUID(), activeTabConnected: true))
    }

    @Test func idleTabsAndClearedSelectionsStayInPlace() {
        #expect(!SidebarOverviewTabPlan.needsNewTab(
            selectedSessionID: UUID(), activeTabConnected: false))
        #expect(!SidebarOverviewTabPlan.needsNewTab(
            selectedSessionID: nil, activeTabConnected: true))
    }
}
