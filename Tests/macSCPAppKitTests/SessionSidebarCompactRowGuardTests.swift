import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// The compact preference must reach both workspaces and hide only auxiliary
/// presentation. Normal mode retains the complete connection metadata.
struct SessionSidebarCompactRowGuardTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/" + name))
    }
    private func body(_ declaration: String, in file: String) throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: code(file))
    }

    @Test func connectionMetadataIsInsideTheNormalModeBranch() throws {
        let row = try body("private struct SessionRow: View", in: "SessionSidebar.swift")
        let details = try TransferQueueBarCancelGuardTests.declarationBody(of: "if !isCompact", in: row)
        #expect(details.contains("Text(kindBadgeLabel)"))
        #expect(details.contains("if let glyph = tunnelGlyph"))
        #expect(details.contains("SidebarTunnelColumn {"))
        let withoutDetails = row.replacingOccurrences(of: details, with: "")
        #expect(row.contains("Text(session.name)"))
        #expect(!withoutDetails.contains("Text(kindBadgeLabel)"))
        #expect(!withoutDetails.contains("if let glyph = tunnelGlyph"))
        #expect(row.contains("isConnected: isConnected, isCompact: isCompact"))
        #expect(row.contains(".padding(.vertical, isCompact ? 2 : 5)"))
        #expect(row.contains("onInput(.doubleClick, session)"))
        #expect(row.contains("onInput(.singleClick, session)"))
    }

    @Test func groupColorControlsAreHiddenInBothCompactWorkspaces() throws {
        let connection = try body("private struct SidebarGroupRow: View", in: "SessionSidebar.swift")
        let connectionDetails = try TransferQueueBarCancelGuardTests.declarationBody(of: "if !isCompact", in: connection)
        #expect(connection.contains("SidebarGroupTitle(name: group.name)"))
        #expect(connectionDetails.contains("GroupColorControl("))
        let tunnels = try body("private func groupSection", in: "TunnelWorkspaceSidebar.swift")
        let tunnelDetails = try TransferQueueBarCancelGuardTests.declarationBody(of: "if !sidebarCompact", in: tunnels)
        #expect(tunnels.contains("SidebarGroupTitle(name: group.name)"))
        #expect(tunnelDetails.contains("GroupColorControl("))
    }

    @Test func compactPreferenceReachesBothWorkspaces() throws {
        let layout = try code("ContentView+Detail.swift")
        #expect(layout.contains("TunnelWorkspaceSidebar(manager:"))
        #expect(layout.contains("decider: tunnelHostKeyDecider, sidebarCompact: settingsStore.sidebarCompact"))
        #expect(layout.contains("SessionSidebar("))
        #expect(layout.contains("sidebarCompact: settingsStore.sidebarCompact,"))
        let identity = try code("SessionSidebarIdentity.swift")
        #expect(identity.contains("if showsConfiguredIcon"))
        #expect(identity.contains("if isConnected && !isCompact"))
        #expect(identity.contains("else if !isCompact"))
        let tunnels = try body("private func tunnelRow", in: "TunnelWorkspaceSidebar.swift")
        #expect(tunnels.contains("TunnelServiceIcon("))
        let status = try TransferQueueBarCancelGuardTests.declarationBody(of: "if !sidebarCompact", in: tunnels)
        #expect(status.contains("Circle().fill(tint(state))"))
        #expect(tunnels.contains("TunnelCatalog.sidebarName(profile, compact: sidebarCompact)"))
    }

    @Test func compactTunnelNamesHideOnlyTheMatchingListenPortSuffix() {
        var profile = TunnelProfile(sessionID: UUID(), name: "harpoon · 18680",
            kind: .local(bind: "127.0.0.1", localPort: 18680, host: "example.invalid", remotePort: 80))
        #expect(TunnelCatalog.sidebarName(profile, compact: true) == "harpoon")
        #expect(TunnelCatalog.sidebarName(profile, compact: false) == "harpoon · 18680")
        #expect(profile.name == "harpoon · 18680")
        profile.name = "My tunnel 18680"
        #expect(TunnelCatalog.sidebarName(profile, compact: true) == profile.name)
        profile.name = "harpoon · 8080"
        #expect(TunnelCatalog.sidebarName(profile, compact: true) == profile.name)
        profile.kind = .remote(bind: "127.0.0.1", remotePort: 8080, localHost: "localhost", localPort: 80)
        #expect(TunnelCatalog.sidebarName(profile, compact: true) == "harpoon")
        profile.kind = .dynamic(bind: "127.0.0.1", localPort: 8080)
        #expect(TunnelCatalog.sidebarName(profile, compact: true) == "harpoon")
        profile.name = " · 8080"
        #expect(TunnelCatalog.sidebarName(profile, compact: true) == profile.name)
    }
}
