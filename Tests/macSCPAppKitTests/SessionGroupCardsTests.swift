import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Session group cards")
@MainActor
struct SessionGroupCardsTests {
    @Test func allConnectionsCardsIncludeGroupedAndUngroupedSessionsWithoutPersistingASyntheticGroup() {
        let group = StoredGroup(name: "Production")
        let values = [session("standalone"), session("web", in: group.id)]
        #expect(SessionGroupCatalog.sessions(in: SessionGroupCatalog.allConnectionsID, sessions: values, groups: [group]) == values)
        #expect(group.id != SessionGroupCatalog.allConnectionsID)
    }

    private struct Presence: SecretPresence {
        let stored: Bool
        func hasSecret(for slot: UUID) -> Bool { stored }
    }

    private func session(_ name: String, in group: UUID? = nil, position: Int = 0) -> StoredSession {
        let icons: [SessionAppearance.Icon] = [.database, .bastion, .ai, .firewall]
        let tints: [SessionAppearance.Tint] = [.purple, .teal, .orange, .red]
        let index = ["database", "bastion", "ai-server", "firewall"].firstIndex(of: name) ?? 0
        var ssh = StoredSSHConfig(host: name == "bastion" ? "bastion-1.infrastructure.example" : "\(name).example",
                                  username: "operator")
        if ["ai-server", "firewall"].contains(name) {
            ssh.jump = .init(host: "bastion-1.infrastructure.example", username: "operator")
        }
        return StoredSession(name: name, groupID: group,
                      ssh: ssh, position: position,
                      appearance: SessionAppearance(icon: icons[index], tint: tints[index]))
    }

    private func card(_ session: StoredSession, stored: Bool = true) -> SessionCardPresentation {
        SessionCardPresentation(session: session, overview: SessionOverviewModel(
            session: session, descriptor: .descriptor(for: session.kind), knownKey: nil,
            secrets: Presence(stored: stored), events: [], groupName: "Production"))
    }

    @Test func catalogIncludesDescendantsInSidebarOrderAndExcludesOtherGroups() {
        let root = StoredGroup(name: "Production")
        let nested = StoredGroup(name: "Databases", parentID: root.id, position: 1)
        let other = StoredGroup(name: "Other")
        let first = session("first", in: root.id, position: 0)
        let last = session("last", in: root.id, position: 2)
        let child = session("child", in: nested.id)
        let hidden = session("hidden", in: other.id)
        let sessions = [last, hidden, child, first]
        let groups = [root, nested, other]
        #expect(SessionGroupCatalog.sessions(in: root.id, sessions: sessions, groups: groups).map(\.id)
                == [first.id, child.id, last.id])
        #expect(SessionGroupCatalog.sessions(in: nested.id, sessions: sessions, groups: groups).map(\.id) == [child.id])
        #expect(SessionGroupCatalog.sessions(in: UUID(), sessions: sessions, groups: groups).isEmpty)
    }

    @Test func damagedGroupCycleDoesNotHangOrDuplicateCards() {
        var first = StoredGroup(name: "First")
        let second = StoredGroup(name: "Second", parentID: first.id)
        first.parentID = second.id
        let record = session("server", in: second.id)
        let result = SessionGroupCatalog.sessions(in: first.id, sessions: [record], groups: [first, second])
        #expect(result.map(\.id) == [record.id])
    }

    @Test func cardsKeepOneLoginAndOmitRedundantGroupAndPaneFacts() {
        let presentation = card(session("server"))
        #expect(presentation.facts.contains { $0.id == "username" })
        #expect(presentation.facts.contains { $0.id == "authentication" })
        #expect(!presentation.facts.contains { $0.id == "group" })
        #expect(!presentation.facts.contains { $0.id == "panes" })
        #expect(presentation.overview.hasStoredSecret == true)
        #expect(card(session("other"), stored: false).overview.hasStoredSecret == false)
        let stored = session("login-set")
        let withLogin = SessionCardPresentation(session: stored, overview: SessionOverviewModel(
            session: stored, descriptor: .descriptor(for: .ssh), knownKey: nil,
            secrets: Presence(stored: true), events: [], loginSetName: "operator"))
        #expect(withLogin.facts.contains { $0.id == "loginSet" })
        #expect(!withLogin.facts.contains { $0.id == "username" })
    }

    @Test func aGroupNeverCoversTrustPromptsOrAnEditDraft() {
        let group = StoredGroup(name: "Production")
        func surface(prompt: Bool = false, mode: ConnectionViewModel.FormMode = .new,
                     liveness: ConnectionLiveness? = nil, failure: Bool = false) -> DetailSurface {
            DetailSurfacePlan.surface(liveness: liveness, hostKeyPromptPending: prompt,
                connectAttemptFailed: failure, describesLostConnection: false,
                unacknowledgedFailure: false, formMode: mode, overviewSession: nil, overviewGroup: group)
        }
        #expect(surface() == .groupOverview(group))
        #expect(surface(prompt: true) == .form)
        #expect(surface(mode: .edit(sessionID: UUID())) == .form)
        #expect(surface(liveness: .connecting) == .connecting)
        #expect(surface(liveness: .lost) == .lost)
        #expect(surface(failure: true) == .failed)
    }

    @Test func URLCredentialsNeverReachCardTextOrTooltips() {
        let marker = "fixture-credential-marker"
        let session = StoredSession(name: "Storage", kind: .s3, s3: StoredS3Config(
            accessKeyID: "fixture-id", region: "eu-west-1", endpoint: "https://fixture:\(marker)@storage.example",
            bucket: "archive", usePathStyle: true, startsAtBucketList: false))
        let presentation = card(session)
        let text = ([presentation.overview.endpointText] + presentation.facts.map(\.text)).joined(separator: " ")
        let credentialWasExposed = text.contains(marker)
        #expect(!credentialWasExposed)
        #expect(presentation.facts.contains { $0.id == "bucket" })
    }

    @Test func groupNavigationIsReadOnlyAndCardActionsUseExistingRoutes() throws {
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let routes = try SourceCorpus.code(of: root.appendingPathComponent("ContentView+SessionGroups.swift"))
        let groupAction = try #require(SourceSpan.body(after: "func showSessionGroup(_ group: StoredGroup)", in: routes))
        #expect(groupAction.contains("guard !sidebarInteractionsDisabled, let tab = formTarget()"))
        #expect(groupAction.contains("tab.overviewGroupID = group.id"))
        #expect(!groupAction.contains("connectFromSidebar("))
        #expect(routes.contains("connectFromSidebar(stored)"))
        let view = try SourceCorpus.code(of: root.appendingPathComponent("SessionGroupOverviewView.swift"))
        #expect(view.contains("struct SessionCardView: View"))
        #expect(view.contains("performSessionRowInput("))
        #expect(view.contains(".onTapGesture(count: 2) { connect(.doubleClick) }"))
        #expect(view.contains("onEdit(card.session)"))
        #expect(view.contains("onDiagnose(card.session)"))
        #expect(view.contains("KeychainSecretPresence()"))
        #expect(!view.contains(".hostKey"))
        #expect(!view.contains(".history"))
        let content = try SourceCorpus.code(of: root.appendingPathComponent("ContentView.swift"))
        let edit = try #require(SourceSpan.body(after: "func editStored(_ stored: StoredSession)", in: content))
        let capture = try #require(edit.range(of: "let sourceGroupID = activeTab.overviewGroupID"))
        let reset = try #require(edit.range(of: "guard let tab = formTarget()"))
        let restore = try #require(edit.range(of: "tab.overviewGroupID = sourceGroupID"))
        #expect(capture.lowerBound < reset.lowerBound)
        #expect(reset.lowerBound < restore.lowerBound)
    }

    @Test func backFromEditingRevealsTheOriginatingGroup() {
        let group = StoredGroup(name: "Production")
        let form = ConnectionViewModel(connector: { _, _ in throw CancellationError() })
        form.beginEditing(session("server", in: group.id))
        func surface() -> DetailSurface {
            DetailSurfacePlan.surface(liveness: nil, hostKeyPromptPending: false, connectAttemptFailed: false,
                describesLostConnection: false, unacknowledgedFailure: false, formMode: form.mode,
                overviewSession: nil, overviewGroup: group)
        }
        #expect(surface() == .form)
        form.endEditing()
        #expect(surface() == .groupOverview(group))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func rendersCardsWithoutAnyKeychainOrNetworkAccess(scheme: ColorScheme) throws {
        let groups = ["Databases", "Infrastructure", "Tools", "Security"].map { StoredGroup(name: $0) }
        let hues = SidebarGroupBands.hues(groups: groups.map(SidebarGroupBands.Group.init))
        let cards = zip(["database", "bastion", "ai-server", "firewall"], groups).map { name, group in
            var presentation = card(session(name, in: group.id))
            presentation.groupHue = hues[group.id]
            return presentation
        }
        // Render the production card directly; lazy grids need a native viewport.
        let renderer = ImageRenderer(content: SessionCardView(card: cards[0],
            onConnect: SessionRowConnectEffect { _ in }, onEdit: { _ in }, onDiagnose: { _ in }).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size == NSSize(width: SessionCardLayout.width, height: SessionCardLayout.height))
    }

    @Test func resizingChangesOnlyTheNumberOfColumns() throws {
        #expect(SessionCardLayout.columnCount(for: 300) == 1)
        #expect(SessionCardLayout.columnCount(for: 620) == 2)
        #expect(SessionCardLayout.columnCount(for: 664) == 2)
        #expect(SessionCardLayout.columnCount(for: 1000) == 3)
        for width: CGFloat in [180, 620, 1400] {
            let renderer = ImageRenderer(content: SessionCardView(card: card(session("server")),
                onConnect: SessionRowConnectEffect { _ in }, onEdit: { _ in }, onDiagnose: { _ in }))
            renderer.proposedSize = ProposedViewSize(width: width, height: 900)
            #expect(try #require(renderer.nsImage).size == NSSize(width: SessionCardLayout.width, height: SessionCardLayout.height))
        }
    }

    @Test func aDefaultWindowFitsThreeCardsWithTheDefaultSidebar() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidebarWidth = SettingsStore(directory: directory).sidebarWidth
        let viewport = MainWindowSizePlan.defaultSize.width - CGFloat(sidebarWidth) - 1
        #expect(SessionCardLayout.columnCount(for: viewport) == 3)
        let widestSidebar = CGFloat(SettingsStore.sidebarWidthRange.upperBound)
        #expect(SessionCardLayout.columnCount(for: MainWindowSizePlan.defaultSize.width - widestSidebar - 1) == 3)
        let restored = MainWindowSizePlan.catalogLaunchSize(current: CGSize(width: 900, height: 600))
        #expect(restored == MainWindowSizePlan.defaultSize)
        let larger = CGSize(width: 1440, height: 900)
        #expect(MainWindowSizePlan.catalogLaunchSize(current: larger) == larger)
        let app = try SourceCorpus.code(of: SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/MacSCPApp.swift"))
        #expect(app.contains(".defaultSize(width: MainWindowSizePlan.defaultSize.width, height: MainWindowSizePlan.defaultSize.height)"))
    }

    @Test func buttonFeedbackHighlightsHoverAndPressButNeverDisabledActions() throws {
        let idle = SessionCardButtonPhase.resolve(enabled: true, hovered: false, pressed: false)
        let hover = SessionCardButtonPhase.resolve(enabled: true, hovered: true, pressed: false)
        let press = SessionCardButtonPhase.resolve(enabled: true, hovered: true, pressed: true)
        #expect(hover.fillOpacity > idle.fillOpacity)
        #expect(press.fillOpacity > hover.fillOpacity)
        #expect(SessionCardButtonPhase.resolve(enabled: false, hovered: true, pressed: true) == .disabled)
        let root = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        let style = try SourceCorpus.code(of: root.appendingPathComponent("SessionCardButtonStyle.swift"))
        #expect(style.contains(".onHover { hovered = $0 }"))
        #expect(style.contains("pressed: configuration.isPressed"))
        #expect(style.contains("accessibilityReduceMotion"))
        let cards = try SourceCorpus.code(of: root.appendingPathComponent("SessionGroupOverviewView.swift"))
        #expect(cards.contains(".buttonStyle(SessionCardButtonStyle())"))
        #expect(cards.contains(".buttonStyle(SessionCardButtonStyle(prominent: true))"))
        #expect(cards.contains("Text(card.overview.endpointText)"))
        #expect(!cards.contains("card.session.comment"))
        let editor = try SourceCorpus.code(of: root.appendingPathComponent("ConnectionFormView.swift"))
        #expect(editor.contains("SessionAppearancePicker("))
        #expect(!editor.contains("$viewModel.comment"))
    }

    @Test func everyRoleUsesAnAvailableSystemSymbolAndTheEditorRenders() async throws {
        for icon in SessionAppearance.Icon.allCases {
            for kind in ConnectionKind.allCases {
                #expect(NSImage(systemSymbolName: icon.symbol(for: kind), accessibilityDescription: nil) != nil)
            }
            #expect(!icon.title.isEmpty)
        }
        for tint in SessionAppearance.Tint.allCases { #expect(!tint.title.isEmpty) }
        let renderer = ImageRenderer(content: VStack {
            SessionAppearancePicker(appearance: .constant(.init(icon: .database, tint: .purple)), kind: .ssh)
        }.frame(width: 620).padding())
        #expect(try #require(renderer.nsImage).isValid)
    }
}
