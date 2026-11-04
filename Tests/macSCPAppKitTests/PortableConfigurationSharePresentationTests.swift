import MacSCPTestSupport
import Testing

@Suite("Portable configuration share presentation")
struct PortableConfigurationSharePresentationTests {
    @Test func sidebarCreatesTheNativePickerOnlyFromTheExplicitShareAction() throws {
        let sourceRoot = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let sidebar = try SourceCorpus.commentFree(
            of: sourceRoot.appendingPathComponent("SessionSidebar.swift"))
        let sharing = try SourceCorpus.commentFree(
            of: sourceRoot.appendingPathComponent("PortableConfigurationShare.swift"))

        #expect(sidebar.components(separatedBy: "Button(action: onShare)").count - 1 == 2)
        #expect(sidebar.contains("onShare: { share(name: group.name, scope: .group(group)) }"))
        #expect(sidebar.contains("onShare: { share(name: session.name, scope: .single(session)) }"))
        #expect(sharing.contains("NSSharingServicePicker(items: [url])"))
        #expect(!sidebar.contains("ShareLink("))

        let rowStart = try #require(sidebar.range(of: "private struct SessionRow: View"))
        let row = sidebar[rowStart.lowerBound...]
        let help = try #require(row.range(of: ".help(connectionSummary)"))
        let menu = try #require(row.range(of: ".contextMenu {"))
        #expect(help.lowerBound < menu.lowerBound)
        #expect(row.contains(".accessibilityLabel(Text(session.name))"))
        #expect(row.contains(".accessibilityValue(Text(connectionSummary))"))
    }
}
