import SwiftUI
import macSCPCore

/// The two names `SessionOverviewModel` renders but `StoredSession` does not
/// carry.
///
/// A session records a `groupID` and a `loginSetID`; the overview shows a
/// group and a login set by NAME, because a rendered UUID is worse than an
/// omitted row (Task 1's report). The lookup lives here, once, so the two
/// ids cannot be resolved one way at the detail pane and another way
/// somewhere else later.
///
/// The group is named by its full path ("Work / Prod"), the label every
/// group picker gives it, read from the same builder
/// (`GroupPickerEntries.build(groups:)`) rather than composed here: two
/// folders named "Prod" under different parents are told apart only by
/// where they sit (final review of the jump-and-groups plan, T5-6).
///
/// An id that names nothing comes back as `nil`, never as the first entry of
/// the list: a group deleted out from under a session must drop the row, not
/// mislabel it. `SessionOverviewModel` omits a fact whose name is `nil` OR
/// empty, so both shapes of "no answer" reach the same place.
enum SessionOverviewNames {
    static func resolve(
        for session: StoredSession, groups: [StoredGroup], loginSets: [LoginSet]
    ) -> (group: String?, loginSet: String?) {
        let groupPath = session.groupID.flatMap { groupID in
            GroupPickerEntries.build(groups: groups).first { $0.id == groupID }?.path
        }
        return (group: groupPath,
                loginSet: loginSets.first { $0.id == session.loginSetID }?.name)
    }
}

struct SessionOverviewView: View {
    let session: StoredSession
    /// Resolved by the window through `SessionOverviewNames` — see that
    /// type for why the model takes names rather than the ids the session
    /// carries.
    let groupName: String?
    let loginSetName: String?
    /// Named `onConnectSession` rather than `onConnect` for one reason,
    /// stated so the next reader does not "tidy" it: the sidebar's own
    /// hand-over of this same effect is pinned in `ContentView+Detail.swift`
    /// by `SessionRowActivationWiringTests`' Guard J, which requires exactly
    /// one line there spelling the sidebar's parameter label followed by the
    /// effect type — and finding `connectFromSidebar(` on it. A second
    /// surface taking a parameter of the SAME label in the same file would
    /// make that anchor ambiguous, and an ambiguous anchor on the one guard
    /// that keeps a stray click from dialling is not a trade worth making
    /// for a shorter name.
    let onConnectSession: SessionRowConnectEffect<StoredSession>
    let onEdit: (StoredSession) -> Void
    /// Both doors onto the diagnostics panel this view offers: the head's
    /// Diagnose control and a failed connection row's "Open diagnosis". One
    /// callback, because they are one door — the window's
    /// `showDiagnostics(for: .stored(…))`, reached with the same session.
    let onDiagnose: (StoredSession) -> Void

    /// `nil` until the stores have been read. The head draws immediately
    /// regardless; the sections below simply are not there yet, which is
    /// why none of them renders an "empty" sentence while `model` is `nil` —
    /// "No connections recorded yet." flashing before the log has been read
    /// would be a claim about a file nobody has opened.
    @State private var model: SessionOverviewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    factsSection
                    historySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keyed on the whole RECORD, not on its id: selecting another row
        // has to rebuild the model, and so does a change to the row already
        // selected — an inline rename or a save writes a new `StoredSession`
        // under the same id, and keying on the id alone would leave the
        // previous version's facts on screen. `StoredSession` is `Equatable`,
        // which is all `task(id:)` asks for, and the comparison runs only
        // when this view is re-evaluated.
        //
        // Everything the loader touches is disk or keychain, which is why it
        // is `nonisolated` and not a main-actor call — see
        // `load(session:groupName:loginSetName:)`.
        .task(id: session) {
            model = nil
            let loaded = await Self.load(
                session: session, groupName: groupName, loginSetName: loginSetName)
            guard !Task.isCancelled else { return }
            model = loaded
        }
    }

    // MARK: - The head (outside the scroll region)

    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // "SCP"/"S3"/"WebDAV" through the backend descriptor, the
                // same way a sidebar row draws its badge — never picked
                // here, so a fourth backend needs a descriptor case and no
                // change at this site.
                Text(kindBadgeLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DesignTokens.inkTertiary)
                Spacer(minLength: 0)
            }

            // The model's, not re-derived here: the descriptor could answer
            // this synchronously, and a second computation of one fact is
            // the second copy this project's rules are about.
            if let endpoint = model?.endpointText, !endpoint.isEmpty {
                Text(endpoint)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindBadgeLabel: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    /// One row where the pane is wide enough, two where it is not — the
    /// fallback `DiagnosticsPanel`'s footer already uses, and for the same
    /// measured reason: below its natural width a `Button` wraps its title
    /// letter by letter rather than shrinking.
    ///
    /// Both layouts draw the SAME three control properties, so
    /// `.keyboardShortcut(.defaultAction)` appears exactly once in this file
    /// no matter which one `ViewThatFits` chooses.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                connectControl
                editControl
                diagnoseControl
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    connectControl
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    editControl
                    diagnoseControl
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var connectControl: some View {
        Button(L10n.string("connection.connect", "Connect")) { openConnection() }
            .buttonStyle(.polished)
            .keyboardShortcut(.defaultAction)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var editControl: some View {
        Button(L10n.string("sidebar.edit", "Edit…")) { onEdit(session) }
            .buttonStyle(.polished)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var diagnoseControl: some View {
        Button(L10n.string("diagnostics.menu", "Diagnose…")) { onDiagnose(session) }
            .buttonStyle(.polished)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The one place this view acts on the effect it holds.
    ///
    /// `.contextMenuEntry` is the input: the user did not make a gesture
    /// whose meaning has to be inferred, they read a button and pressed it —
    /// which is exactly what that case is for
    /// (`SessionRowInput.isMenuEntry`). The three other effect slots are
    /// no-ops constructed right here rather than parameters of this view, so
    /// this surface HOLDS no way to open a terminal, local or external, and
    /// `onSelect` has nothing to do: the overview is on screen because this
    /// row is already the selection.
    private func openConnection() {
        performSessionRowInput(
            .contextMenuEntry, on: session, isRenaming: false, isSelected: true,
            onSelect: SessionRowSelectEffect { _ in },
            onConnect: onConnectSession,
            onOpenTerminal: SessionRowTerminalEffect { _ in },
            onOpenExternalTerminal: SessionRowExternalTerminalEffect { _ in })
    }

    // MARK: - Facts

    /// One labelled line of the facts grid, after the App has resolved the
    /// model's label key out of its own catalogues.
    private struct Line: Identifiable {
        let id: String
        let label: String
        let text: String
        let isMonospaced: Bool
    }

    /// The model's facts plus the two answers it carries outside that list:
    /// what is known about the host key, and whether a secret is stored.
    ///
    /// Both are appended rather than emitted by Core because neither is a
    /// datum out of the stored record — one comes from the known-hosts
    /// store, the other from a keychain metadata query — and both have a
    /// state that means "there is nothing to say here", which drops the row
    /// instead of labelling a blank.
    private var lines: [Line] {
        guard let model else { return [] }
        var lines = model.facts.map {
            // A dynamic key, so the English source text cannot sit at this
            // call site the way `L10n.string("sidebar.edit", "Edit…")`'s
            // does; `en.lproj` holds it, and the id is the fallback if the
            // resource bundle cannot be found at all. Same shape as the
            // sidebar's own badge, which resolves
            // `descriptor.badgeLabelKey`.
            Line(id: $0.id, label: L10n.string($0.labelKey, $0.id), text: $0.text,
                 isMonospaced: $0.isMonospaced)
        }
        if let line = hostKeyLine(model.hostKey) { lines.append(line) }
        if let line = secretLine(model.hasStoredSecret) { lines.append(line) }
        return lines
    }

    /// `.notApplicable` yields no row at all: telling an S3 user their host
    /// key is unknown would be an answer to a question their protocol does
    /// not ask (`HostKeyStatus`' own doc comment).
    private func hostKeyLine(_ status: HostKeyStatus) -> Line? {
        let label = L10n.string("overview.hostKey", "Host key")
        switch status {
        case .known(let type, let fingerprint):
            return Line(id: "hostKey", label: label, text: "\(type) \(fingerprint)",
                        isMonospaced: true)
        case .unknown:
            return Line(
                id: "hostKey", label: label,
                text: L10n.string("overview.hostKey.unknown", "Not known yet — the next connect asks"),
                isMonospaced: false)
        case .notApplicable:
            return nil
        }
    }

    /// `nil` yields no row: a login that keeps its key in the ssh-agent
    /// stores nothing, and "no secret stored" would read there as a warning
    /// about a setup that is complete.
    private func secretLine(_ stored: Bool?) -> Line? {
        guard let stored else { return nil }
        return Line(
            id: "secret", label: L10n.string("overview.secret", "Password"),
            text: stored
                ? L10n.string("overview.secret.stored", "Saved in the keychain")
                : L10n.string("overview.secret.missing", "Not saved — asked at connect"),
            isMonospaced: false)
    }

    @ViewBuilder
    private var factsSection: some View {
        if model != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.string("overview.section.facts", "Details"))
                ViewThatFits(in: .horizontal) {
                    factsGrid(columns: 2)
                    factsGrid(columns: 1)
                }
            }
        }
    }

    /// The lines laid out `columns` at a time.
    ///
    /// Written once and called twice — `ViewThatFits` measures the
    /// two-column form first and falls through to the one-column form — so
    /// the cell itself, and everything it decides about type and selection,
    /// exists in exactly one place regardless of which one is drawn.
    ///
    /// A short last row is left short: `GridRow` fills the leading columns
    /// and leaves the rest empty, which is the wanted shape. There is no
    /// padding cell, and no row at all when there are no lines.
    private func factsGrid(columns: Int) -> some View {
        let all = lines
        let rows: [[Line]] = stride(from: 0, to: all.count, by: columns).map { start in
            Array(all[start..<min(start + columns, all.count)])
        }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { line in
                        factCell(line)
                    }
                }
            }
        }
    }

    private func factCell(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(line.label)
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
            Text(line.text)
                .font(line.isMonospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(DesignTokens.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recent connections

    @ViewBuilder
    private var historySection: some View {
        if let model {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.string("overview.section.history", "Recent connections"))
                if model.history.isEmpty {
                    Text(Self.historyEmptyLabel(recordingEnabled: DiagnosticLog.shared.isEnabled(.error)))
                        .font(.callout)
                        .foregroundStyle(DesignTokens.inkTertiary)
                } else {
                    // The transfers column is what goes first when the pane
                    // narrows: it is a count beside an outcome, where the
                    // outcome is the sentence the row exists to say. The
                    // audit log remains the full record either way.
                    ViewThatFits(in: .horizontal) {
                        historyTable(model.history, showsTransfers: true)
                        historyTable(model.history, showsTransfers: false)
                    }
                }
            }
        }
    }

    private func historyTable(
        _ rows: [ConnectionHistory.Row], showsTransfers: Bool
    ) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                columnTitle(L10n.string("overview.history.column.started", "Started"))
                columnTitle(L10n.string("overview.history.column.outcome", "Outcome"))
                if showsTransfers {
                    columnTitle(L10n.string("overview.history.column.transfers", "Transfers"))
                }
                Color.clear.frame(height: 0)
            }
            ForEach(rows) { row in
                GridRow {
                    Text(row.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.inkSecondary)
                    outcomeCell(row.outcome)
                    if showsTransfers {
                        Text(transfersText(row))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkTertiary)
                    }
                    // The failed row's own door onto the panel — the same
                    // `showDiagnostics(for: .stored(…))` the head's control
                    // reaches, with the same session.
                    if case .failed = row.outcome {
                        Button(L10n.string("overview.history.diagnose", "Open diagnosis")) {
                            onDiagnose(session)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeCell(_ outcome: ConnectionHistory.Row.Outcome) -> some View {
        switch outcome {
        case .connected(let duration):
            Text(
                duration.map(Self.durationText)
                    // No duration: the log carries a connect that was never
                    // closed — this session, or one the app did not shut
                    // down cleanly. "Still open" would be a claim about now
                    // that a finished log cannot support.
                    ?? L10n.string("overview.history.noEnd", "No disconnect recorded")
            )
            .font(.caption)
            .foregroundStyle(DesignTokens.inkSecondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(DesignTokens.statusLost)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func durationText(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    /// Uploads, downloads and failures as three counted symbols. Deliberately
    /// not a sentence with plurals: the three numbers are the point, and a
    /// symbol carries no plural category to get wrong in four languages.
    private func transfersText(_ row: ConnectionHistory.Row) -> String {
        String(
            format: L10n.string(
                "overview.history.transfers %1$lld %2$lld %3$lld", "↑%1$lld ↓%2$lld ✗%3$lld"),
            row.uploads, row.downloads, row.failedTransfers)
    }


    private var supportsShell: Bool {
        BackendDescriptor.descriptor(for: session.kind).capabilities.supportsShell
    }

    // MARK: - Shared bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DesignTokens.inkTertiary)
            .textCase(.uppercase)
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DesignTokens.inkTertiary)
    }

    // MARK: - Loading

    nonisolated static func historyEmptyLabel(recordingEnabled: Bool) -> String {
        recordingEnabled
            ? L10n.string("overview.history.empty", "Nothing recorded for this connection yet.")
            : L10n.string("overview.history.disabled", "Connection history is recorded only when diagnostic logging is enabled in Settings.")
    }

    nonisolated static func load(
        session: StoredSession, groupName: String?, loginSetName: String?,
        directory: URL = SessionStore.defaultDirectory,
        secrets: any SecretPresence = KeychainSecretPresence()
    ) async -> SessionOverviewModel {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        // SSH only, and by the stored block rather than by `kind`: the
        // known-hosts store is keyed on the host and port this session
        // dials, and a record with no SSH block names neither.
        var knownKey: KnownHostKey?
        if let ssh = session.ssh {
            knownKey = try? KnownHostsStore(directory: directory)
                .find(host: ssh.host, port: ssh.port)
        }
        return SessionOverviewModel(
            session: session, descriptor: descriptor, knownKey: knownKey,
            secrets: secrets,
            events: AuditLogStore(directory: directory.appendingPathComponent("audit", isDirectory: true))
                .events(for: session.id),
            groupName: groupName, loginSetName: loginSetName)
    }
}
