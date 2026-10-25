import Testing
@testable import MacSCPAppKit

@Suite("Session sidebar visibility")
struct SidebarVisibilityPolicyTests {
    @Test(arguments: [false, true])
    func selectingAnUnconnectedTabAlwaysRevealsSessions(wasVisible: Bool) {
        #expect(SidebarVisibilityPolicy.selectingTab(isVisible: wasVisible, hasSession: false))
    }

    @Test(arguments: [false, true])
    func switchingConnectedTabsPreservesTheUsersChoice(wasVisible: Bool) {
        #expect(SidebarVisibilityPolicy.selectingTab(isVisible: wasVisible, hasSession: true) == wasVisible)
    }
}
