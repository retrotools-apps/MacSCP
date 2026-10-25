import Foundation
import MacSCPTestSupport
import Testing

@Suite("Group context menu consistency")
struct GroupContextMenuTests {
    @Test func bothGroupMenusUseSharedTermsAndKeepColorOnTheSwatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["SessionSidebar.swift", "TunnelWorkspaceSidebar.swift"] {
            let source = try SourceCorpus.commentFree(of: root.appendingPathComponent("Sources/MacSCPAppKit/\(name)"))
            for key in ["sidebar.group.dissolve", "sidebar.rename", "sidebar.newGroup", "sidebar.moveTo"] {
                #expect(source.contains("\"\(key)\""), "\(name) must share \(key)")
            }
            #expect(source.contains("GroupColorControl("))
            #expect(!source.contains("Button(L10n.string(\"group.color\""))
            #expect(!source.contains("tunnels.group.remove"))
        }
        let control = try SourceCorpus.commentFree(of: root.appendingPathComponent("Sources/MacSCPAppKit/SidebarGroupBands.swift"))
        #expect(control.contains(".popover(isPresented:"))
        #expect(control.contains(".help(L10n.string(\"group.color\""))
    }
}
