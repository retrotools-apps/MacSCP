import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Tunnel workspace", .timeLimit(.minutes(1)))
@MainActor
struct TunnelWorkspacePresentationTests {
    @Test func tunnelsPrecedeGroupsAtEveryLevelAndKeepTheirAlphabeticalOrder() {
        let root = TunnelGroup(name: "A root")
        let child = TunnelGroup(name: "A child", parentID: root.id)
        let sibling = TunnelGroup(name: "B child", parentID: root.id)
        let nested = TunnelGroup(name: "A nested", parentID: child.id)
        func profile(_ name: String, _ groupID: UUID?) -> TunnelProfile {
            TunnelProfile(sessionID: UUID(), name: name, kind: .dynamic(bind: "127.0.0.1", localPort: 19080), groupID: groupID)
        }
        let loose = profile("Zulu loose", nil), z = profile("Zulu", root.id)
        let a = profile("Alpha", root.id), deep = profile("Zulu deep", child.id)
        let groups = [sibling, nested, child, root], profiles = [z, loose, deep, a]
        let rows = TunnelCatalog.sidebarRows(groups: groups, profiles: profiles, collapsed: [])
        #expect(rows.map(\.id) == [loose.id, root.id, a.id, z.id, child.id, deep.id, nested.id, sibling.id])
        #expect(rows == [.profile(loose, depth: 0), .group(.init(group: root, depth: 0)),
            .profile(a, depth: 1), .profile(z, depth: 1), .group(.init(group: child, depth: 1)),
            .profile(deep, depth: 2), .group(.init(group: nested, depth: 2)), .group(.init(group: sibling, depth: 1))])
        #expect(TunnelCatalog.sidebarRows(groups: groups, profiles: profiles, collapsed: [child.id]).map(\.id)
            == [loose.id, root.id, a.id, z.id, child.id, sibling.id])
    }

    @Test func tunnelAppearanceUsesTheConnectionFormInsteadOfAHiddenPopover() throws {
        let path = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/TunnelAppearancePicker.swift")
        let code = try SourceCorpus.code(of: path)
        #expect(code.contains("struct TunnelAppearancePicker: View"))
        #expect(code.contains("SessionAppearancePicker(appearance: Binding("))
        #expect(!code.contains(".popover("))
    }
    @Test(arguments: TunnelAppearance.Icon.allCases)
    func serviceIconsHaveLocalizedTitlesAndAvailableSymbols(icon: TunnelAppearance.Icon) {
        #expect(!icon.title.isEmpty)
        #expect(icon.symbol == icon.symbol(for: .ssh))
        #expect(NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) != nil)
    }

    @Test func editingADraftPreservesItsServiceAppearanceAndRouting() throws {
        let profile = TunnelProfile(sessionID: UUID(), name: "Database",
            kind: .local(bind: "127.0.0.1", localPort: 15432, host: "db.example", remotePort: 5432),
            appearance: .init(icon: .database, tint: .purple, applicationLogo: "mysql"))
        var draft = TunnelProfileDraft(profile: profile)
        #expect(try draft.profile(id: profile.id, sessionID: profile.sessionID).get() == profile)
        draft.appearance = .init(icon: .api, tint: .teal)
        let edited = try draft.profile(id: profile.id, sessionID: profile.sessionID).get()
        #expect(edited.appearance == draft.appearance)
        #expect(edited.kind == profile.kind)
        #expect(edited.sessionID == profile.sessionID)
    }

    @Test func editorKeepsAutostartButLeavesGroupManagementAndGenericRouteProseOutsideTheForm() throws {
        let path = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/TunnelWorkspaceView.swift")
        let code = try SourceCorpus.code(of: path)
        #expect(code.contains("struct TunnelWorkspaceEditor: View"))
        #expect(code.contains("selection: $draft.autoStart"))
        #expect(!code.contains("selection: $draft.groupID"))
        let text = try SourceCorpus.commentFree(of: path)
        #expect(text.contains("tunnels.autostart"))
        #expect(!text.contains("tunnels.flow.localHelp"))
        #expect(!text.contains("tunnels.flow.remoteHelp"))
    }

    @Test func nestedCatalogFiltersAndDisclosureUseTheSameTree() {
        let root = TunnelGroup(name: "Production")
        let child = TunnelGroup(name: "Web", parentID: root.id)
        let leaf = TunnelGroup(name: "API", parentID: child.id)
        let other = TunnelGroup(name: "Development")
        let groups = [root, child, leaf, other]
        let profiles = groups.map {
            TunnelProfile(sessionID: UUID(), name: $0.name,
                          kind: .dynamic(bind: "127.0.0.1", localPort: 19080), groupID: $0.id)
        }
        #expect(TunnelCatalog.profiles(selection: .group(root.id), profiles: profiles, groups: groups)
            == [profiles[2], profiles[0], profiles[1]])
        #expect(TunnelCatalog.profiles(selection: .group(child.id), profiles: profiles, groups: groups)
            == [profiles[2], profiles[1]])
        let rows = TunnelCatalog.rows(groups: groups, collapsed: [])
        #expect(rows.map(\.id) == [other.id, root.id, child.id, leaf.id])
        #expect(rows.map(\.depth) == [0, 0, 1, 2])
        #expect(TunnelCatalog.rows(groups: groups, collapsed: [root.id]).map(\.id) == [other.id, root.id])
        #expect(TunnelCatalog.rows(groups: groups, collapsed: [child.id]).map(\.id) == [other.id, root.id, child.id])
    }

    @Test func catalogSeparatesGroupsAndSingleTunnelSelections() throws {
        let first = TunnelGroup(name: "Production"), second = TunnelGroup(name: "Development")
        func mapping(_ groupID: UUID?) -> TunnelProfile {
            TunnelProfile(sessionID: UUID(), name: "Web", kind: .dynamic(bind: "127.0.0.1", localPort: 19080), groupID: groupID)
        }
        let a = mapping(first.id), b = mapping(second.id), loose = mapping(nil), orphan = mapping(UUID())
        let profiles = [a, b, loose, orphan], groups = [first, second]
        #expect(TunnelCatalog.profiles(selection: .group(first.id), profiles: profiles, groups: groups) == [a])
        #expect(TunnelCatalog.profiles(selection: .profile(b.id), profiles: profiles, groups: groups) == [b])
        #expect(TunnelCatalog.profiles(selection: .ungrouped, profiles: profiles, groups: groups) == [loose, orphan])
        #expect(TunnelCatalog.profiles(selection: .all, profiles: profiles, groups: groups) == profiles)
        #expect(TunnelCatalog.profiles(selection: .group(UUID()), profiles: profiles, groups: groups).isEmpty)
        let draft = TunnelProfileDraft(profile: a)
        let rebuilt = try draft.profile(id: a.id, sessionID: a.sessionID).get()
        #expect(rebuilt.groupID == first.id)
    }
    @Test func manualFailureDoesNotLeaveAnOngoingSessionAlarm() {
        var profile = TunnelProfile(sessionID: UUID(), name: "Web", kind: .dynamic(bind: "127.0.0.1", localPort: 19080))
        let failure = TunnelState.failed(.portInUse(port: 19080))
        let summary = TunnelPresentationState.sessionSummary(profile: profile, state: failure)
        #expect(summary == .stopped)
        #expect(TunnelGlyphPlan.glyph(states: [summary])?.tint == .grey)
        #expect(TunnelPresentationState.canDismiss(failure))
        #expect(TunnelPresentationState.canStopAll([failure]))
        for mode in [TunnelProfile.AutoStart.appStart, .login] {
            profile.autoStart = mode
            #expect(TunnelPresentationState.sessionSummary(profile: profile, state: failure) == failure)
            #expect(TunnelPresentationState.sessionSummary(profile: profile, state: .stopped) == .stopped)
        }
        profile.autoStart = .off
        profile.reconnects = true
        let retryFailure = TunnelPresentationState.sessionSummary(profile: profile, state: failure)
        #expect(retryFailure == failure)
        #expect(TunnelGlyphPlan.glyph(states: [retryFailure])?.tint == .red)
        #expect(TunnelPresentationState.sessionSummary(profile: profile, state: .stopped) == .stopped)
    }

    @Test func clearingFailuresIsNeverOfferedForAnActiveOrConnectingTunnel() {
        let profile = TunnelProfile(sessionID: UUID(), name: "Web", kind: .dynamic(bind: "127.0.0.1", localPort: 19080))
        for state in [TunnelState.connecting, .reconnecting(attempt: 1), .active(connections: 2)] {
            #expect(!TunnelPresentationState.canDismiss(state))
            #expect(TunnelPresentationState.sessionSummary(profile: profile, state: state) == state)
            #expect(TunnelPresentationState.canStopAll([state]))
        }
        #expect(!TunnelPresentationState.canStopAll([.stopped]))
        #expect(!TunnelPresentationState.canDismiss(.stopped))
    }

    @Test func doubleClickStopsRunningTunnelsAndStartsEveryIdleState() {
        for state in [TunnelState.connecting, .reconnecting(attempt: 1), .active(connections: 2)] {
            #expect(TunnelPresentationState.toggleAction(for: state) == .stop)
        }
        for state in [TunnelState.stopped, .failed(.portInUse(port: 19080)), .needsConfirmation] {
            #expect(TunnelPresentationState.toggleAction(for: state) == .start)
        }
    }

    @Test func tunnelRowsAndTheirButtonUseTheSameToggleRoute() throws {
        let path = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/TunnelWorkspaceView.swift")
        let code = try SourceCorpus.commentFree(of: path)
        #expect(code.contains(".onTapGesture(count: 2) { toggleTunnel(profile) }"))
        #expect(code.components(separatedBy: "toggleTunnel(profile)").count - 1 == 2)
        let toggle = try #require(SourceSpan.body(after: "private func toggleTunnel(_ profile: TunnelProfile)", in: code))
        #expect(toggle.contains("TunnelPresentationState.toggleAction"))
        #expect(toggle.contains("manager.start(profile, decider: decider)"))
        #expect(toggle.contains("manager.stop(profile)"))
    }
    @Test func requestedTrendsSymbolAlwaysHasAVisibleTemplateImage() {
        #expect(TunnelSymbols.tunnel == "apple.health.trends")
        #expect(TunnelSymbols.image.isValid)
        let fallback = TunnelSymbols.makeImage(preferredImage: nil)
        #expect(fallback.isTemplate)
        #expect(fallback.isValid)
        #expect(fallback.size == NSSize(width: 32, height: 32))
    }

    private final class PreviewRunner: TunnelRunning {
        nonisolated let states: AsyncStream<TunnelState>
        private let publish: AsyncStream<TunnelState>.Continuation
        init() { (states, publish) = AsyncStream.makeStream(of: TunnelState.self) }
        func start(decider: HostKeyDecider) async { publish.yield(.active(connections: 2)) }
        func stop() async { publish.yield(.stopped) }
    }

    @Test func draftPreservesBrowserProtocolAndJumpOverride() throws {
        let profile = TunnelProfile(sessionID: UUID(), name: "Web", kind: .local(
            bind: "127.0.0.1", localPort: 19080, host: "service.example", remotePort: 80),
            service: .https, jumpSessionID: UUID())
        let rebuilt = try TunnelProfileDraft(profile: profile).profile(id: profile.id, sessionID: profile.sessionID).get()
        #expect(rebuilt == profile)
    }

    @Test func conflictingSavePreservesStoredAndRunningProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TunnelStore(directory: directory)
        let existing = TunnelProfile(sessionID: UUID(), name: "Web", kind: .dynamic(bind: "127.0.0.1", localPort: 19080))
        try store.upsert(existing)
        let manager = TunnelManager(store: store, makeRunner: { profile in
            TunnelRunner(profile: profile, connect: { _ in throw TunnelRefusal.sessionMissing })
        }, sessionIDs: { nil })
        let conflict = TunnelProfile(sessionID: UUID(), name: "Other", kind: .local(
            bind: "0.0.0.0", localPort: 19080, host: "service.example", remotePort: 80))
        await #expect(throws: TunnelPortConflictError.self) { try await manager.save(conflict) }
        #expect(store.allProfiles() == [existing])
        #expect(manager.allProfiles == [existing])
    }

    @Test(arguments: [ColorScheme.light, .dark], [1200.0, 900.0])
    func workspaceRendersWithoutNetworkOrKeychain(scheme: ColorScheme, width: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ssh = StoredSSHConfig(host: "gateway.example", username: "operator", authKind: .agent)
        ssh.tlsTunnel = try SSHTLSTunnelConfig(host: "tls.example", verifyCertificate: false)
        let session = StoredSession(name: "Gateway", ssh: ssh)
        let store = TunnelStore(directory: directory)
        let group = TunnelGroup(name: "Production")
        try store.upsertGroup(group)
        let subgroup = TunnelGroup(name: "Web", parentID: group.id)
        try store.upsertGroup(subgroup)
        for index in 0..<3 {
            try store.upsert(TunnelProfile(sessionID: session.id, name: ["Web console", "Database", "Development"][index],
                kind: .local(bind: "127.0.0.1", localPort: 19080 + index, host: "service.example", remotePort: 8080),
                autoStart: index == 0 ? .appStart : .off, reconnects: true, service: index == 0 ? .https : .tcp,
                groupID: index == 0 ? subgroup.id : index == 1 ? group.id : nil,
                appearance: .init(icon: [.secureWeb, .database, .remoteDesktop][index],
                                  tint: [.blue, .purple, .teal][index])))
        }
        let manager = TunnelManager(store: store, makeRunner: { _ in PreviewRunner() }, sessionIDs: { [session.id] })
        let active = try #require(manager.allProfiles.first { $0.service == .https })
        await manager.start(active, decider: .refusing)
        try await pollUntil("the preview runner publishes its active state") {
            manager.state(of: active.id) == .active(connections: 2)
        }
        let view = HStack(spacing: 0) {
            TunnelWorkspaceSidebar(manager: manager, onSessions: {}).frame(width: 200)
            Divider()
            TunnelWorkspaceView(manager: manager, sessions: [session], decider: .refusing)
        }.frame(width: width, height: 680).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        let rendered = try #require(renderer.nsImage)
        #expect(rendered.isValid)
        await manager.stopAll()
    }

    @Test func choosingTheEndpointDisplaysItsSavedBastionAndTLSWithoutAnotherSelection() throws {
        var ssh = StoredSSHConfig(host: "gateway.example", username: "operator", authKind: .agent)
        ssh.tlsTunnel = try SSHTLSTunnelConfig(host: "tls.example")
        let gateway = StoredSession(name: "Bastion", ssh: ssh)
        let endpoint = StoredSession(name: "Application server", ssh: .init(
            host: "app.example", username: "operator", authKind: .agent,
            jump: .init(host: "", username: "", sessionID: gateway.id)))
        let route = TunnelRoutePresentation(carrierID: endpoint.id, overrideID: nil, sessions: [endpoint, gateway])
        #expect(route.endpointName == endpoint.name)
        #expect(route.gatewayName == gateway.name)
        #expect(route.tls == ssh.tlsTunnel)
        #expect(!route.overridesSavedRoute)
        let direct = TunnelRoutePresentation(carrierID: gateway.id, overrideID: nil, sessions: [endpoint, gateway])
        #expect(direct.gatewayName == nil)
        #expect(direct.tls == ssh.tlsTunnel)
    }

    @Test func existingOverridesRemainVisibleAndDistinctFromTheSavedRoute() {
        let gateway = StoredSession(name: "Bastion", ssh: .init(host: "gateway.example", username: "operator"))
        let endpoint = StoredSession(name: "Application server", ssh: .init(host: "app.example", username: "operator"))
        let route = TunnelRoutePresentation(carrierID: endpoint.id, overrideID: gateway.id, sessions: [endpoint, gateway])
        #expect(route.gatewayName == gateway.name)
        #expect(route.overridesSavedRoute)
        let reset = TunnelRoutePresentation(carrierID: endpoint.id, overrideID: nil, sessions: [endpoint, gateway])
        #expect(reset.gatewayName == nil)
        #expect(!reset.overridesSavedRoute)
    }
}
