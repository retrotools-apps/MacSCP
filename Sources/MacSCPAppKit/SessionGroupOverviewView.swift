import SwiftUI
import macSCPCore

enum SessionCardLayout {
    static let width: CGFloat = 280
    static let height: CGFloat = 148
    static let spacing: CGFloat = 12
    static let inset: CGFloat = 20

    static func columnCount(for viewportWidth: CGFloat) -> Int {
        max(1, Int((max(0, viewportWidth - inset * 2) + spacing) / (width + spacing)))
    }
}

struct SessionCardPresentation: Identifiable, Sendable {
    let session: StoredSession
    let overview: SessionOverviewModel
    var groupHue: Double? = nil
    var groupColor: GroupColor? = nil
    var darkerNeutral = false
    var id: UUID { session.id }
    var facts: [SessionOverviewModel.Fact] {
        let hasLogin = overview.facts.contains { $0.id == "loginSet" }
        return overview.facts.filter {
            !["group", "endpoint", "baseURL"].contains($0.id) && !(hasLogin && $0.id == "username")
        }.map { fact in
            guard fact.id == "username" else { return fact }
            return .init(id: fact.id, labelKey: "card.login", text: fact.text, isMonospaced: true)
        }
    }
    var authenticationSymbol: String {
        switch session.ssh?.authKind {
        case .privateKey: "key"
        case .agent: "person.crop.circle"
        case .password, nil: "lock"
        }
    }
}

struct SessionGroupOverviewView: View {
    let group: StoredGroup
    let sessions: [StoredSession]
    let groups: [StoredGroup]
    let loginSets: [LoginSet]
    let onConnectSession: SessionRowConnectEffect<StoredSession>
    let onEdit: (StoredSession) -> Void
    let onDiagnose: (StoredSession) -> Void
    @State private var cards: [SessionCardPresentation] = []

    private struct Request: Equatable {
        let sessions: [StoredSession]
        let groups: [StoredGroup]
        let loginSets: [LoginSet]
    }

    var body: some View {
        SessionCardsGrid(
            name: GroupPickerEntries.build(groups: groups).first { $0.id == group.id }?.path ?? group.name,
            cards: cards, isLoading: cards.isEmpty && !sessions.isEmpty,
            onConnect: onConnectSession, onEdit: onEdit, onDiagnose: onDiagnose)
        .task(id: Request(sessions: sessions, groups: groups, loginSets: loginSets)) {
            cards = []
            let loaded = await Self.load(sessions: sessions, groups: groups, loginSets: loginSets)
            guard !Task.isCancelled else { return }
            cards = loaded
        }
    }

    /// Only secret presence is queried. No host-key/history file or secret
    /// value is needed to render a group; disk and vault work stays off MainActor.
    nonisolated static func load(
        sessions: [StoredSession], groups: [StoredGroup], loginSets: [LoginSet]
    ) async -> [SessionCardPresentation] {
        var cards: [SessionCardPresentation] = []
        let hues = SidebarGroupBands.hues(groups: groups.map(SidebarGroupBands.Group.init))
        let neutralVariants = SidebarGroupBands.neutralVariants(groups: groups.map(SidebarGroupBands.Group.init))
        for session in sessions {
            guard !Task.isCancelled else { break }
            let names = SessionOverviewNames.resolve(for: session, groups: groups, loginSets: loginSets)
            cards.append(SessionCardPresentation(session: session, overview: SessionOverviewModel(
                session: session, descriptor: BackendDescriptor.descriptor(for: session.kind),
                knownKey: nil, secrets: KeychainSecretPresence(), events: [],
                groupName: names.group, loginSetName: names.loginSet),
                groupHue: session.groupID.flatMap { hues[$0] },
                groupColor: groups.first { $0.id == session.groupID }?.color,
                darkerNeutral: session.groupID.flatMap { neutralVariants[$0] } ?? false))
        }
        return cards
    }
}

struct SessionCardsGrid: View {
    let name: String
    let cards: [SessionCardPresentation]
    var isLoading = false
    let onConnect: SessionRowConnectEffect<StoredSession>
    let onEdit: (StoredSession) -> Void
    let onDiagnose: (StoredSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(name, systemImage: "folder")
                .help(name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(SessionCardLayout.inset)
                .accessibilityAddTraits(.isHeader)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cards.isEmpty {
                L10n.text("group.cards.empty", "No saved sessions in this group.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(SessionCardLayout.width),
                            spacing: SessionCardLayout.spacing),
                            count: SessionCardLayout.columnCount(for: viewport.size.width)),
                                  alignment: .leading, spacing: SessionCardLayout.spacing) {
                            ForEach(cards) { card in
                                SessionCardView(card: card, onConnect: onConnect, onEdit: onEdit,
                                                onDiagnose: onDiagnose)
                            }
                        }
                        .padding(.horizontal, SessionCardLayout.inset)
                        .padding(.bottom, SessionCardLayout.inset)
                        .frame(width: max(viewport.size.width, SessionCardLayout.width + SessionCardLayout.inset * 2),
                               alignment: .leading)
                        .frame(minHeight: viewport.size.height, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SessionCardView: View {
    let card: SessionCardPresentation
    let onConnect: SessionRowConnectEffect<StoredSession>
    let onEdit: (StoredSession) -> Void
    let onDiagnose: (StoredSession) -> Void
    @Environment(\.highContrast) private var highContrast
    @Environment(\.groupColorsEnabled) private var colorsEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var descriptor: BackendDescriptor { .descriptor(for: card.session.kind) }
    private var appearance: SessionAppearance { card.session.appearance ?? SessionAppearance() }
    private var groupInk: Color? {
        guard highContrast, card.groupHue != nil || card.groupColor != nil else { return nil }
        return GroupSurfaceStyle.foreground(hue: card.groupHue ?? 0.62, customColor: card.groupColor,
            darkerNeutral: card.darkerNeutral, dark: scheme == .dark, colorsEnabled: colorsEnabled)
    }


    private var cardHeader: some View {
        HStack(spacing: 9) {
            AppearanceIcon(icon: appearance.icon, applicationLogo: appearance.applicationLogo, kind: card.session.kind, size: 19)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(highContrast ? .white : appearance.displayColor)
                .frame(width: 28, height: 28)
                .background(appearance.displayColor.opacity(highContrast ? 1 : 0.09), in: RoundedRectangle(cornerRadius: highContrast ? 14 : 7))
                .help(L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault))
                .accessibilityHidden(true)
            Text(card.overview.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                .help(card.overview.name)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault))
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }
    }

    private var cardEndpoint: some View {
        Text(card.overview.endpointText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(card.overview.endpointText)
    }

    private var cardFacts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.facts.filter { $0.id != "authentication" }) { fact in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: fact.id)).frame(width: 13)
                        Text(fact.text).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11, design: fact.isMonospaced ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .help("\(L10n.string(fact.labelKey, fact.id)): \(fact.text)")
                    .accessibilityLabel("\(L10n.string(fact.labelKey, fact.id)): \(fact.text)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var cardActions: some View {
        HStack(spacing: 6) {
            Button(L10n.string("connection.connect", "Connect")) { connect(.contextMenuEntry) }
                .buttonStyle(SessionCardButtonStyle(prominent: true))
            Spacer(minLength: 4)
            if let auth = card.facts.first(where: { $0.id == "authentication" }) {
                Image(systemName: card.authenticationSymbol)
                    .help(auth.text).accessibilityLabel(auth.text)
            }
            if let stored = card.overview.hasStoredSecret {
                let hint = stored
                    ? L10n.string("overview.secret.stored", "Saved in the keychain")
                    : L10n.string("overview.secret.missing", "Not saved — asked at connect")
                Image(systemName: stored ? "lock.shield" : "lock.open")
                    .help(hint).accessibilityLabel(hint)
            }
            Button { onEdit(card.session) } label: {
                Image(systemName: "pencil")
            }
            .help(L10n.string("sidebar.edit", "Edit…"))
            .accessibilityLabel(L10n.string("sidebar.edit", "Edit…"))
            Button { onDiagnose(card.session) } label: {
                Image(systemName: "stethoscope")
            }
            .help(L10n.string("diagnostics.menu", "Diagnose…"))
            .accessibilityLabel(L10n.string("diagnostics.menu", "Diagnose…"))
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .controlSize(.small)
        .buttonStyle(SessionCardButtonStyle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            cardEndpoint
            cardFacts
            cardActions
        }
        .foregroundStyle(groupInk ?? .primary, groupInk?.opacity(0.85) ?? .secondary,
                         groupInk?.opacity(0.75) ?? .secondary)
        .padding(14)
        .frame(width: SessionCardLayout.width, height: SessionCardLayout.height, alignment: .topLeading)
        .background {
            GroupContentTint(hue: card.groupHue, darkerNeutral: card.darkerNeutral, customColor: card.groupColor)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .background(DesignTokens.sessionCardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
            hovered ? DesignTokens.remoteBlue.opacity(0.45) : Color.primary.opacity(0.09), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2) { connect(.doubleClick) }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }

    private func connect(_ input: SessionRowInput) {
        performSessionRowInput(
            input, on: card.session, isRenaming: false, isSelected: true,
            onSelect: SessionRowSelectEffect { _ in }, onConnect: onConnect,
            onOpenTerminal: SessionRowTerminalEffect { _ in },
            onOpenExternalTerminal: SessionRowExternalTerminalEffect { _ in })
    }

    private func symbol(for fact: String) -> String {
        switch fact {
        case "username": "person"
        case "group": "folder"
        case "loginSet": "person.crop.rectangle"
        case "keyPath": "key"
        case "jump": "network"
        case "bucket": "externaldrive"
        case "region": "globe"
        default: "info.circle"
        }
    }
}
