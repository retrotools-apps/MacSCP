import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@MainActor struct SidebarNativeLayoutTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func hierarchicalSidebarRendersInANativeList(scheme: ColorScheme, compact: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let root = StoredGroup(name: "Phantom", color: GroupColor(rgb: 0xE6E673))
        let child = StoredGroup(name: "Deception", parentID: root.id, color: GroupColor(rgb: 0xE673AC))
        let tools = StoredGroup(name: "Tools", parentID: root.id, color: GroupColor(rgb: 0xAC73E6))
        for group in [root, child, tools] { try store.upsertGroup(group) }
        for (name, group) in [("z-bastion", root.id), ("phantom-central", child.id), ("phantom-pop1", child.id), ("phantom-pop2", child.id), ("AI server", tools.id), ("dns server", tools.id)] {
            try store.upsert(StoredSession(name: name, groupID: group, ssh: StoredSSHConfig(host: "example.invalid", username: "operator")))
        }
        let model = SessionListViewModel(store: store, secrets: NoSecretsStore(), auditStore: AuditLogStore(directory: directory), loginSetStore: LoginSetStore(directory: directory), keys: ManagedKeyStore(directory: directory))
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        for (index, session) in model.sessions.enumerated() {
            try rig.store.upsert(TunnelProfile(sessionID: session.id, name: "Preview tunnel",
                kind: .local(bind: "127.0.0.1", localPort: 25000 + index, host: "example.invalid", remotePort: 80)))
        }
        rig.manager.reload()
        let sidebar = SessionSidebar(viewModel: model, activeSessionID: nil, connectedSessionIDs: [], interactionsDisabled: false,
            onConnect: .init { _ in }, onDelete: { _ in .init(restored: 0, secretFailures: 0) }, onNew: {},
            onSelectSession: { _ in }, onSelectGroup: { _ in }, selectedGroupID: root.id, onEdit: { _ in },
            onOpenTerminal: .init { _ in }, onOpenExternalTerminal: .init { _ in }, onExport: { _ in }, onImport: {},
            onShowAuditLog: { _ in }, onDiagnose: { _ in }, tunnels: rig.manager, onStartTunnel: .init { _ in },
            onStopTunnel: { _ in }, onStartAllTunnels: .init { _ in }, onStopAllTunnels: { _ in }, onManageTunnels: { _ in },
            onShowKnownHosts: {}, onShowLogins: {}, sidebarCompact: compact)
        let host = NSHostingView(rootView: sidebar.environment(\.highContrast, true).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 330, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["MACSCP_SIDEBAR_PREVIEW"] {
            let target = path + (compact ? ".compact.png" : "") + (scheme == .dark ? ".dark.png" : "")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: target))
        }
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        let table = try #require(tables(host).first)
        let visibility = SidebarVisibility.compute(sessions: model.sessions, groups: model.groups, importedHostsCount: 0, search: nil)
        let projected = SidebarVisibleRows.build(under: nil, visibility: visibility, collapsed: [])
        let start = table.numberOfRows - projected.count
        #expect(start >= 0)
        for group in [root, child, tools] {
            let offset = try #require(projected.firstIndex { $0.id == group.id })
            #expect(table.rect(ofRow: start + offset).height <= (group.parentID == nil ? 34 : 28))
        }
        // The final descendant reserves its own bottom margin and the parent's frame.
        #expect(table.rect(ofRow: table.numberOfRows - 1).height >= (compact ? 36 : 42))
    }

    @Test(arguments: [false, true])
    func tunnelSidebarRendersBothDensities(compact: Bool) async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let group = TunnelGroup(name: "Services", color: GroupColor(rgb: 0x73E6D0))
        try rig.store.upsertGroup(group)
        try rig.store.upsert(TunnelProfile(sessionID: UUID(), name: "harpoon · 18680",
            kind: .local(bind: "127.0.0.1", localPort: 18680, host: "example.invalid", remotePort: 80), groupID: group.id))
        rig.manager.reload()
        let host = NSHostingView(rootView: TunnelWorkspaceSidebar(manager: rig.manager, sidebarCompact: compact, onSessions: {})
            .environment(\.highContrast, true).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 330, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let path = ProcessInfo.processInfo.environment["MACSCP_TUNNEL_SIDEBAR_PREVIEW"] {
            let target = path + (compact ? ".compact.png" : "")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: target))
        }
    }

    @Test func tunnelFilterUsesAMiniNativeSwitch() async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let host = NSHostingView(rootView: TunnelWorkspaceView(manager: rig.manager, sessions: [], decider: .refusing))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func switches(_ view: NSView) -> [NSSwitch] { (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap(switches) }
        let toggle = try #require(switches(host).first)
        #expect(toggle.controlSize == .mini)
        if let path = ProcessInfo.processInfo.environment["MACSCP_TUNNEL_PREVIEW"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }


    @Test(arguments: [ColorScheme.light, .dark])
    func collapsedLabelsAreCenteredWithinTheirOwnGroupSurface(scheme: ColorScheme) async throws {
        let metrics = CollapsedSidebarMetrics()
        let home = StoredGroup(name: "Home", color: GroupColor(rgb: 0x8FE673))
        let root = StoredGroup(name: "Phantom", color: GroupColor(rgb: 0xE6E673))
        let child = StoredGroup(name: "Deception", parentID: root.id, color: GroupColor(rgb: 0xE673AC))
        let tools = StoredGroup(name: "Tools", parentID: root.id, color: GroupColor(rgb: 0xAC73E6))
        let groups = [home, root, child, tools]
        let bands = SidebarGroupBands.build(entries: groups.map { .init(id: $0.id, groupID: $0.id) }, groups: groups.map(SidebarGroupBands.Group.init))
        let fixture = SidebarList {
            ForEach(groups) { group in
                let layers = bands[group.id] ?? []
                let own = layers.last!
                SidebarGroupHeader(isExpanded: .constant(!own.ends), name: group.name) {
                    HStack {
                        SidebarGroupTitle(name: group.name)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("collapsedSidebar")) }) {
                                metrics.labels[group.id] = $0
                            }
                        Spacer()
                        GroupColorControl(hue: nil, color: group.color, isPresented: .constant(false), onChange: { _ in })
                    }.padding(.vertical, 1).padding(.horizontal, 2)
                }
                .modifier(SidebarGroupForeground(layers: layers))
                .padding(.leading, SidebarIndentation.leading(depth: own.depth))
                .padding(.top, own.depth == 0 ? 8 : 2)
                .padding(.bottom, SidebarGroupBands.headerBottomInset(for: layers))
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowBackground(SidebarGroupBandBackground(layers: layers)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("collapsedSidebar")) }) {
                        metrics.backgrounds[group.id] = $0
                    })
            }
        }.coordinateSpace(name: "collapsedSidebar")
            .environment(\.highContrast, true).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: fixture)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 330, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        for group in [home, child, tools] {
            let label = try #require(metrics.labels[group.id])
            let row = try #require(metrics.backgrounds[group.id])
            let layers = try #require(bands[group.id])
            let own = try #require(layers.last)
            let top: CGFloat = own.depth == 0 ? 8 : 2
            let bottom = SidebarGroupBands.bottomBackgroundInset(for: own, in: layers)
            let center = (row.minY + top + row.maxY - bottom) / 2
            #expect(abs(label.midY - center) <= 0.5)
        }
        if let path = ProcessInfo.processInfo.environment["MACSCP_COLLAPSED_PREVIEW"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: scheme == .light ? path : path + ".dark.png"))
        }
    }

}


@MainActor private final class CollapsedSidebarMetrics {
    var labels: [UUID: CGRect] = [:]
    var backgrounds: [UUID: CGRect] = [:]
}
