import SwiftUI
import macSCPCore

enum SessionRowTerminalMenuPlan: Equatable {
    /// The backend has no shell (S3, WebDAV): neither entry is drawn at all.
    case hidden
    /// The backend has a shell (SSH): both entries are offered.
    case shown

    var isShown: Bool { self == .shown }

    static func build(for kind: ConnectionKind) -> SessionRowTerminalMenuPlan {
        BackendDescriptor.descriptor(for: kind).capabilities.supportsShell ? .shown : .hidden
    }
}

enum SessionRowTunnelMenuPlan: Equatable {
    /// No submenu: this session can carry no forwarding.
    case hidden
    /// The submenu, with one entry per stored profile — possibly none, in
    /// which case only "Manage forwardings…" is left to draw.
    case shown(entries: [Entry])

    /// One profile, and the one fact the menu draws differently for.
    struct Entry: Equatable, Identifiable {
        let profile: TunnelProfile
        let isRunning: Bool
        var id: UUID { profile.id }
    }

    var isShown: Bool {
        if case .shown = self { return true }
        return false
    }

    var entries: [Entry] {
        if case .shown(let entries) = self { return entries }
        return []
    }

    /// `state` is asked per profile rather than handed in as a dictionary so
    /// the caller can be the manager itself — one reading of the states, not
    /// a copy that can already be stale by the time the menu opens.
    static func build(
        for session: StoredSession, profiles: [TunnelProfile],
        state: (UUID) -> TunnelState
    ) -> SessionRowTunnelMenuPlan {
        guard TunnelCarriers.carries(session.kind) else { return .hidden }
        return .shown(entries: profiles.map { profile in
            Entry(
                profile: profile,
                isRunning: TunnelManager.Aggregate.isRunning(state(profile.id)))
        })
    }
}

/// Left column: stored connections and folders, drawn as a tree of arbitrary
/// depth. A click selects a connection, a double click or Return connects it;
/// context menus cover connect/edit/rename/duplicate/move/delete on connections,
/// rename/export/sort/dissolve on folders, and new-connection/new-group on
/// the background. The phosphor dot marks the active connection.
///
/// **This view derives no place for anything.** Which rows sit under which
/// parent, and in which order, is `SidebarVisibility.children(of:)`'s answer;
/// where a dropped row lands is `SessionListViewModel.move(_:before:)`'s or
/// `move(_:intoGroup:)`'s, each given two identities. See
/// `SidebarOrdering`'s doc comment for why an index carried through a view
/// was the defect class this shape removed, and `SidebarTreeWiringTests` for
/// the guard that keeps one from creeping back in here.
struct SessionSidebar: View {
    let viewModel: SessionListViewModel
    let activeSessionID: UUID?
    let connectedSessionIDs: Set<UUID>
    let interactionsDisabled: Bool
    /// Opens a connection to one stored session.
    ///
    /// The first of this sidebar's host-reaching callbacks — five of them
    /// since the port-forwarding plan's Task 6 (this one, the two terminal
    /// ones, and `onStartTunnel`/`onStartAllTunnels` below), and every one
    /// is an effect value rather than a closure. This view cannot fire any
    /// of them: their `run` is private to the file that declares them, and
    /// `SessionRowActivation.apply` — the only code that runs one of the
    /// first three — is `fileprivate` there too. What is reachable from
    /// here is `performSessionRowInput`, which states an input and the two
    /// facts about the row and picks nothing. The two tunnel effects are
    /// fired by naming a menu entry instead (`SessionRowTunnelActivation`),
    /// because they act on a profile rather than on the session an input
    /// carries.
    ///
    /// Fix round 2 gave `onConnect` that shape; round 3 put the firing
    /// decision out of reach; round 4 extended both to the two terminal
    /// callbacks, which had stayed plain closures while being connects —
    /// `onOpenTerminal(session)`, written into the function that moves the
    /// selection, dialled on every single click with the whole suite green.
    let onConnect: SessionRowConnectEffect<StoredSession>
    /// Performs the actual deletion and returns the jump-restoration outcome
    /// (M11a/T3) — the sidebar surfaces `secretFailures` as its own red
    /// inline message, same pattern as `LoginSetsSheet.deleteSelected()`.
    let onDelete: (StoredSession) -> SessionListViewModel.JumpRestoreResult
    let onNew: () -> Void
    /// Which STORED session the sidebar is pointing at, reported upward every
    /// time the user points at one — not only when the id changes (session
    /// overview plan, Task 2).
    ///
    /// The window shows a read-only overview of this session in the detail
    /// area of an unconnected tab, so "the selection" has to be a fact the
    /// window can read; `selectedSessionID` is `@State` here and stays that
    /// way, because where the pointer is remains this view's own business.
    /// `nil` says the sidebar points at no stored session: the
    /// "New connection" row, or an entry from `~/.ssh/config`, both of which
    /// put the FORM on screen and would be contradicted by an overview
    /// hanging on behind it.
    ///
    /// Fired on every activation rather than on a change, deliberately:
    /// clicking the row that is already selected is how a user gets the
    /// overview back after opening the form from it, and an
    /// `onChange(of:)`-shaped report would answer that click with silence.
    ///
    /// A plain callback and not an effect value, under the rule stated at
    /// `onConnect`: a selection reaches nothing but this window.
    let onSelectSession: (UUID?) -> Void
    let onSelectGroup: (StoredGroup) -> Void
    /// The active tab owns group browsing, so switching tabs cannot leave a
    /// folder highlighted while a different workspace is displayed.
    let selectedGroupID: UUID?
    var onAllConnections: () -> Void = {}
    let onEdit: (StoredSession) -> Void
    /// Session-row "Open Terminal" entry (P3c/T2) — connects exactly the way
    /// `onConnect` does and differs from it in the pane layout alone (the
    /// session comes up showing the terminal instead of the file browser).
    /// Only ever offered when the backend has a shell — see
    /// `SessionRowTerminalMenuPlan`. Because it connects, it is an effect
    /// value under the rule stated at `onConnect`, and the entry that runs
    /// it is an input (`.terminalMenuEntry`), not a callback the row holds.
    let onOpenTerminal: SessionRowTerminalEffect<StoredSession>
    /// Session-row "Open in External Terminal" entry (P3c/T2) — resolves the
    /// session's configuration and hands it to the external terminal;
    /// MacSCP itself does NOT connect. Same visibility rule as
    /// `onOpenTerminal`, and the same effect-value rule: the dialling
    /// program differs, the host reached does not.
    let onOpenExternalTerminal: SessionRowExternalTerminalEffect<StoredSession>
    /// Sidebar export entries (M9a/T3): session/group/background context
    /// menus all funnel into this one callback with the scope they cover.
    let onExport: (SessionListViewModel.ExportScope) -> Void
    let onImport: () -> Void
    /// Sidebar session menu "Audit Log…" entry (M9b/T3) — opens the sheet
    /// for any stored session, connected or not.
    let onShowAuditLog: (StoredSession) -> Void
    /// Sidebar session menu "Diagnose…" entry (design §1, the session menu's
    /// door) — opens the diagnostics panel for any stored session, connected
    /// or not.
    ///
    /// A plain callback rather than a `SessionRowConnectEffect`, and the rule
    /// for that split is what the entry DOES: opening the panel reaches no
    /// host. The probes inside it — including an SSH dial that authenticates
    /// — run when the user presses the panel's own button, never when a menu
    /// entry is clicked (decision of 2026-09-02). Same category as `onEdit`
    /// and `onShowAuditLog`; if this ever opened a panel that ran on appear,
    /// it would belong with `onConnect` instead.
    let onDiagnose: (StoredSession) -> Void
    /// The app-wide port forwardings (port-forwarding plan, Task 6) — read
    /// for the row's "Port forwarding" submenu, which asks
    /// `SessionRowTunnelMenuPlan.build` what to draw. Not a per-window value
    /// and deliberately not one: a forwarding belongs to no window, and
    /// `TunnelManager` is process-wide for that reason.
    let tunnels: TunnelManager
    /// Starts ONE forwarding — an effect value, not a closure, because it
    /// dials the user's host (see `SessionRowStartTunnelEffect`).
    let onStartTunnel: SessionRowStartTunnelEffect<TunnelProfile>
    /// Stops one forwarding. A plain callback: stopping reaches nobody.
    let onStopTunnel: (TunnelProfile) -> Void
    /// Starts every forwarding of one session — an effect value for the same
    /// reason as `onStartTunnel`.
    let onStartAllTunnels: SessionRowStartAllTunnelsEffect<StoredSession>
    let onStopAllTunnels: (StoredSession) -> Void
    /// Opens the profile sheet for this session. Opening it dials nothing.
    let onManageTunnels: (StoredSession) -> Void
    let onShowKnownHosts: () -> Void
    /// Background context menu "Logins…" entry (M10b/T3) — opens the
    /// login-sets management sheet, directly below "Known Hosts…".
    let onShowLogins: () -> Void
    /// Compact sidebar mode (sidebar-polish plan, Task 2; extended to
    /// folder rows 2026-09-05) — `SettingsStore.sidebarCompact`, read by
    /// `ContentView` and handed over as a plain fact: nothing in this file has to know a
    /// settings layer exists. Forwarded as `isCompact` to each
    /// `SessionRow` (row padding only, 5pt to 2pt) AND to each
    /// `SidebarGroupRow` (folder padding only, 3pt to 1pt) — no ordering,
    /// no selection behaviour, no keyboard handling, and no other element
    /// of either row: the session row's protocol badge stays visible in
    /// both densities (fix round 2, coordinator ruling 2026-09-04 — see
    /// `SessionRow.isCompact`'s own doc comment).
    let sidebarCompact: Bool
    var onShowTunnels: () -> Void = {}
    var onShowSettings: () -> Void = {}

    /// Folder disclosure is local view state.
    @State private var collapsedGroups: Set<UUID> = []
    @State private var groupsWithHiddenEntries: Set<UUID> = []

    /// Which session row the sidebar's selection sits on — the row a double
    /// click or Return connects, and the only thing a single click changes.
    ///
    /// View state because a pointer position is not a setting. It is deliberately unrelated to
    /// `activeSessionID`, which says which session the ACTIVE TAB has
    /// connected; a user can point at one session while another is on
    /// screen, and both facts are drawn on the row (see
    /// `SessionRowHighlight`).
    @State private var selectedSessionID: UUID?
    /// Keyboard focus for the selected row, so Return reaches it.
    ///
    /// SwiftUI writes this as well as this view does — focus moves for
    /// reasons no code here initiates (a rename field taking over, Tab
    /// traversal under Full Keyboard Access, the window losing key status),
    /// which is why it is not enough to set it once and assume it stays.
    /// Two rules keep it and the selection from drifting apart: every write
    /// from this view moves both (`moveSelection(to:)`, and `endRename`
    /// giving the keyboard back afterwards), and a focus arriving from
    /// anywhere else pulls the selection after it (`onChange(of:
    /// focusedRowID)`). A row that holds the focus is therefore the row
    /// that is highlighted, which is the row Return connects.
    @FocusState private var focusedRowID: UUID?

    /// Shared inline-rename state: works for both session rows and group
    /// headers, since only one row can be renaming at a time.
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @FocusState private var focusedRenameID: UUID?

    @State private var isShowingNewGroupAlert = false
    @State private var newGroupName: String = ""
    /// Set when "New group…" is triggered from a session's "Move to" menu —
    /// the session to move into the freshly created group. `nil` for the
    /// background/toolbar "New group…" entry, which only creates the group.
    @State private var sessionPendingGroupMove: StoredSession?
    /// Set when "New group…" is triggered from a FOLDER's own context menu
    /// (Task 4, jump-and-groups plan) — the folder the new group is nested
    /// inside. `nil` for the background/toolbar and session "Move to…"
    /// entries, which both create a top-level group, exactly as before this
    /// task.
    @State private var pendingNewGroupParentID: UUID?

    /// The sidebar's shared note of which row a drag is carrying — written
    /// by each row's own drag payload, read when a drop is targeted on
    /// another. See `SidebarDragOrigin` for why it is a box rather than
    /// state, and for what it is worth.
    @State private var dragOrigin = SidebarDragOrigin()

    @State private var sessionPendingDelete: StoredSession?
    /// Red inline message after a delete whose jump-restoration pass
    /// (M11a/T3) hit a keychain failure — same pattern as
    /// `LoginSetsSheet.deleteErrorMessage`.
    @State private var jumpRestoreErrorMessage: String?

    var body: some View {
        // Saved sessions use the shared tree decision.
        let visibility = SidebarVisibility.compute(
            sessions: viewModel.sessions,
            groups: viewModel.groups,
            importedHostsCount: 0,
            search: nil)

        VStack(alignment: .leading, spacing: 0) {
            SidebarWorkspaceHeading(title: L10n.string("sidebar.header", "SESSIONS"))
                // The one place a row can be sent back to the top level:
                // dropping it on the sidebar's own title. A folder that fills
                // the whole list would otherwise leave nothing outside itself
                // to drop onto.
                .dropDestination(for: String.self) { payload, _ in
                    drop(payload, intoGroup: nil)
                }

            SidebarList {
                Button {
                    guard !interactionsDisabled, renamingID == nil else { return }
                    selectedSessionID = nil
                    onAllConnections()
                } label: {
                    SidebarNavigationLabel(title: L10n.string("sidebar.allConnections", "All connections"), symbol: "square.grid.2x2")
                }
                .help(L10n.string("sidebar.allConnections", "All connections"))
                .buttonStyle(.plain)
                .listRowBackground(selectedGroupID == SessionGroupCatalog.allConnectionsID
                    ? DesignTokens.remoteBlue.opacity(0.12) : Color.clear)
                Button(action: startNewConnection) {
                    SidebarNavigationLabel(title: L10n.string("sidebar.newConnection", "New connection"), symbol: "plus.rectangle.on.rectangle")
                }
                .help(L10n.string("sidebar.newConnection", "New connection"))
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                Divider().listRowSeparator(.hidden)

                switch visibility.emptiness {
                case .notEmpty:
                    rows(under: nil, visibility: visibility)

                case .noSessionsAtAll:
                    emptyStateRow(
                        message: L10n.string("sidebar.empty.noSessions", "No saved connections yet."),
                        showsClearFilter: false)
                case .filterMatchesNothing:
                    emptyStateRow(
                        message: L10n.string("sidebar.empty.noMatches", "No connection matches the filter."),
                        showsClearFilter: true)
                }
            }
            // Rows are flattened for presentation with explicit indentation;
            // native DisclosureGroup nesting adds unwanted outline columns.
            .listStyle(.plain)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .contextMenu {
                backgroundMenu
            }
            .onChange(of: focusedRenameID) { _, newValue in
                // Focus lost without an explicit commit (which already
                // clears `renamingID` itself) — cancel silently, never
                // commit on blur.
                //
                // Deliberately NOT `endRename()`: the first responder went
                // somewhere else on purpose here, and handing the keyboard
                // back to the selected row would take it off whatever the
                // user just moved to.
                if newValue == nil, renamingID != nil {
                    renamingID = nil
                }
            }
            .onChange(of: focusedRowID) { _, newValue in
                guard !interactionsDisabled else { return }
                // Focus reached a row by a path that is not `activate` —
                // Tab traversal under Full Keyboard Access is the one that
                // exists today. The selection follows, so a focused row is
                // never an invisible stop that Return does nothing on, and
                // the highlight keeps naming the row the keyboard acts on.
                // Only ever follows focus ONTO a row: focus leaving the
                // sidebar must not clear a selection the user can still see.
                if let newValue {
                    selectedSessionID = newValue
                    // The report follows the selection here too: this is the
                    // one path that moves it without going through
                    // `moveSelection(to:)`, and a detail pane left on the
                    // previous row's overview while the highlight sits on
                    // another is precisely the drift this branch exists to
                    // repair.
                    onSelectSession(newValue)
                }
            }
            groupMoveErrorBanner

            jumpRestoreErrorBanner
        }
        .disabled(interactionsDisabled)
        .allowsHitTesting(!interactionsDisabled)
        .overlay {
            if interactionsDisabled {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SessionSidebarToolbar(navigationDisabled: interactionsDisabled, onTunnels: onShowTunnels, onSettings: onShowSettings,
                groupsAvailable: !viewModel.groups.isEmpty,
                onCollapseGroups: {
                    groupsWithHiddenEntries = Set(viewModel.groups.map(\.id))
                    let parents = Set(viewModel.groups.compactMap(\.parentID))
                    collapsedGroups = groupsWithHiddenEntries.subtracting(parents)
                },
                onExpandGroups: { collapsedGroups.removeAll(); groupsWithHiddenEntries.removeAll() })
        }
        .background(DesignTokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            // Purely cosmetic edge — must never shadow scrollbar hits.
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .alert(
            SidebarNewGroupAlertPlan.title(parentID: pendingNewGroupParentID, groups: viewModel.groups),
            isPresented: $isShowingNewGroupAlert
        ) {
            TextField(L10n.string("sidebar.newGroup.placeholder", "Group name"), text: $newGroupName)
            Button(L10n.string("sidebar.newGroup.create", "Create")) {
                commitNewGroup()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                newGroupName = ""
                sessionPendingGroupMove = nil
                pendingNewGroupParentID = nil
            }
        }
        .confirmationDialog(
            String(
                format: L10n.string("sidebar.delete.confirmTitle %@", "Delete \u{201C}%@\u{201D}?"),
                sessionPendingDelete?.name ?? ""),
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { isPresented in if !isPresented { sessionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("sidebar.delete", "Delete"), role: .destructive) {
                if let session = sessionPendingDelete {
                    let result = onDelete(session)
                    // Partial keychain-restore failure (M11a/T3): surfaced
                    // as a red inline message, never silently dropped — same
                    // pattern as `LoginSetsSheet.deleteSelected()`.
                    jumpRestoreErrorMessage = result.secretFailures > 0
                        ? String(
                            format: L10n.string(
                                "sidebar.delete.jumpRestoreError %lld",
                                "Could not restore the stored password for %lld connections."),
                            result.secretFailures)
                        : nil
                }
                sessionPendingDelete = nil
            }
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    /// The confirmation dialog's message: the existing "credentials removed"
    /// notice, plus (M11a/T3, spec §4d) a count of sessions that reference
    /// this one as their jump host, when any do — they keep working after
    /// the delete because `SessionListViewModel.delete(_:)` restores their
    /// jump to concrete values first (spec §4 "delete = restoration").
    private var deleteConfirmMessage: String {
        let base = L10n.string(
            "sidebar.delete.confirmMessage", "The saved credentials are removed as well.")
        guard let session = sessionPendingDelete else { return base }
        // Restoration (and thus the "will keep its data directly" claim
        // below) only happens for an SSH bastion -- `SessionListViewModel
        // .delete` leaves the reference dangling for any other kind, so a
        // non-SSH session must not be counted here.
        let count = session.kind == .ssh ? viewModel.sessionsUsingAsJump(session.id).count : 0
        guard count > 0 else { return base }
        let jumpNote = String(
            format: L10n.string(
                "sidebar.delete.jumpUsage %lld",
                "%lld connections use this connection as their jump host and will keep its data directly."),
            count)
        return base + "\n\n" + jumpNote
    }

    // MARK: - Error banners

    /// How long a dismissible red caption in this sidebar stays before it
    /// clears itself (dev-build follow-up, 2026-09-03: the maintainer saw
    /// `core.session.groupMoveCycle` sit on screen with nothing to close
    /// it). Six seconds is long enough to read a sentence, short enough that
    /// a resolved refusal does not linger. Named so
    /// `SessionSidebarErrorGuardTests` can read it from the source instead
    /// of pinning a repeated literal.
    private static let errorAutoDismissDelay: Duration = .seconds(6)

    /// Shared by the group-move and Keychain-restore error captions. Each
    /// passes its message and dismissal: the view model's dismissError or
    /// a direct local State write, respectively.
    ///
    /// The close button calls `onDismiss()` directly, and `.task(id:
    /// message)` restarts the six-second countdown every time the caller's
    /// message itself changes — a new refusal after an old one was
    /// dismissed gets its own full six seconds, since SwiftUI cancels and
    /// re-runs a `.task(id:)` whose id changed. The countdown is cancelled,
    /// and so never fires, whenever the calling banner stops calling this at
    /// all — including the moment its own message becomes `nil`, since that
    /// is exactly when its `if let` stops drawing it.
    @ViewBuilder
    private func sidebarErrorBanner(
        message: String, onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(L10n.string("sidebar.error.dismiss", "Dismiss"))
            .accessibilityLabel(L10n.string("sidebar.error.dismiss", "Dismiss"))
        }
        .padding(8)
        .task(id: message) {
            do {
                try await Task.sleep(for: Self.errorAutoDismissDelay)
                onDismiss()
            } catch {
                // Cancelled by a message change or the view going away —
                // either way, not this task's job to clear anything.
            }
        }
    }

    /// `viewModel.errorMessage` (`core.session.groupMoveCycle` and the other
    /// `SessionListViewModel` failures) through the shared
    /// `sidebarErrorBanner(message:onDismiss:)` above — dismissal goes
    /// straight to `viewModel.dismissError()`, the one call that actually
    /// clears this particular message.
    @ViewBuilder
    private var groupMoveErrorBanner: some View {
        if let errorMessage = viewModel.errorMessage {
            sidebarErrorBanner(message: errorMessage) {
                viewModel.dismissError()
            }
        }
    }

    /// Same shared treatment as `groupMoveErrorBanner`, for the partial
    /// keychain-restore notice set at `sessionPendingDelete` above
    /// (M11a/T3) — local `@State`, so dismissal writes
    /// `jumpRestoreErrorMessage` directly rather than going through the view
    /// model.
    @ViewBuilder
    private var jumpRestoreErrorBanner: some View {
        if let jumpRestoreErrorMessage {
            sidebarErrorBanner(message: jumpRestoreErrorMessage) {
                self.jumpRestoreErrorMessage = nil
            }
        }
    }

    // MARK: - Row builders

    /// One flat ForEach with stable identities. Only the data projection
    /// recurses; List never has to reconcile a type-erased, variable number
    /// of sibling views under a single group's identity.
    private func rows(under parentID: UUID?, visibility: SidebarVisibility) -> some View {
        let rows = SidebarVisibleRows.build(under: parentID, visibility: visibility, collapsed: collapsedGroups,
                                            hiddenEntries: groupsWithHiddenEntries)
        let bands = SidebarGroupBands.connections(rows, visibility: visibility, groups: viewModel.groups)
        return ForEach(rows) { row in
            switch row.item {
            case .session(let id):
                if let session = visibility.session(id) {
                    sessionRow(session)
                        .padding(.leading, SidebarIndentation.leading(depth: row.depth))
                        .padding(.trailing, SidebarIndentation.leading(depth: row.depth))
                        .listRowBackground(SidebarGroupBandBackground(layers: bands[row.id] ?? []))
                }
            case .group(let id):
                if let group = visibility.group(id) {
                    SidebarGroupHeader(
                        isExpanded: expansion(
                            of: group.id, expandsFolders: visibility.expandsFolders),
                        name: group.name,
                        isSelected: selectedGroupID == group.id
                    ) {
                        groupRow(group)
                            .onTapGesture(count: 1) {
                                selectGroup(group)
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { selectGroup(group) }
                    }
                    .padding(.leading, SidebarIndentation.leading(depth: row.depth))
                    .listRowInsets(EdgeInsets(top: row.depth == 0 ? 8 : 2, leading: 4, bottom: 2, trailing: 4))
                    .listRowSeparator(.hidden)
                    .listRowBackground(SidebarGroupBandBackground(layers: bands[row.id] ?? []))
                }
            }
        }
    }

    /// Whether one folder is open. Not persisted — every folder starts open
    /// again on relaunch, the same as before folders could nest.
    ///
    /// Both halves are `SidebarFolderDisclosure`'s answer, not this view's:
    /// what the folder draws as, and what the triangle writes — including
    /// the case where it writes nothing at all, which is what keeps a search
    /// from rearranging the user's folders behind their back. `nil` back
    /// from `collapsed(_:setting:open:expandsFolders:)` is "do not write",
    /// while toolbar actions can replace the complete collapse set.
    private func expansion(of groupID: UUID, expandsFolders: Bool) -> Binding<Bool> {
        Binding(
            get: {
                SidebarFolderDisclosure.isOpen(
                    groupID, collapsed: collapsedGroups, expandsFolders: expandsFolders)
            },
            set: { open in
                if let updated = SidebarFolderDisclosure.collapsed(
                    collapsedGroups, setting: groupID, open: open,
                    expandsFolders: expandsFolders)
                {
                    collapsedGroups = updated
                    if open { groupsWithHiddenEntries.remove(groupID) }
                }
            })
    }

    @ViewBuilder
    private func groupRow(_ group: StoredGroup) -> some View {
        SidebarGroupRow(
            group: group,
            isRenaming: renamingID == group.id,
            renameDraft: $renameDraft,
            focusedRenameID: $focusedRenameID,
            dragOrigin: dragOrigin,
            // The real stored children, not a presentation subset:
            // the sort rewrites the whole folder, so a folder showing one row
            // while holding three has something to sort. What the count means
            // is `SidebarSortMenuPlan`'s answer, not this line's.
            sortPlan: SidebarSortMenuPlan.build(childCount: viewModel.children(of: group.id).count),
            groups: viewModel.groups,
            isCompact: sidebarCompact,
            onStartRename: { startRename(id: group.id, currentName: group.name) },
            onCommitRename: { commitGroupRename(group) },
            onCancelRename: endRename,
            onExport: { onExport(.group(group)) },
            onColor: { viewModel.setGroupColor(group, color: $0) },
            onSortByName: { viewModel.sortChildrenByName(of: group.id) },
            onNewGroup: { beginNewGroup(forMoving: nil, inGroup: group.id) },
            onDissolve: { viewModel.dissolveGroup(group) },
            // The same call a drop onto another folder makes, so the menu
            // and the gesture put a folder in the same place.
            onMove: { parentID in viewModel.move(.group(group.id), intoGroup: parentID) },
            onDrop: { payload in drop(payload, intoGroup: group.id) })
    }

    @ViewBuilder
    private func sessionRow(_ session: StoredSession) -> some View {
        SessionRow(
            session: session,
            isActive: session.id == activeSessionID,
            isConnected: connectedSessionIDs.contains(session.id),
            isSelected: session.id == selectedSessionID,
            isRenaming: renamingID == session.id,
            renameDraft: $renameDraft,
            focusedRenameID: $focusedRenameID,
            focusedRowID: $focusedRowID,
            groups: viewModel.groups,
            isCompact: sidebarCompact,
            // Handed over as the activation method itself, not wrapped
            // in a closure: a closure here would be a second place
            // where an input could be swapped for another on its way
            // to the plan, and review round 2 planted exactly that.
            onInput: activate(_:on:),
            onEdit: { onEdit(session) },
            onStartRename: { startRename(id: session.id, currentName: session.name) },
            onCommitRename: { commitSessionRename(session) },
            onCancelRename: endRename,
            // The same call a drop onto a folder makes, so the menu and
            // the gesture put a connection in the same place — at the end
            // of that folder, with the ranks rewritten. The plain field
            // write (`moveSession`) leaves the connection's old rank
            // behind, which reads as an arbitrary place in its new folder.
            onMove: { groupID in viewModel.move(.session(session.id), intoGroup: groupID) },
            onRequestNewGroupMove: { beginNewGroup(forMoving: session) },
            onDuplicate: { duplicate(session) },
            onRequestDelete: { sessionPendingDelete = session },
            onExport: { onExport(.single(session)) },
            onShowAuditLog: { onShowAuditLog(session) },
            onDiagnose: { onDiagnose(session) },
            tunnels: tunnels,
            onStartTunnel: onStartTunnel,
            onStopTunnel: onStopTunnel,
            onStartAllTunnels: onStartAllTunnels,
            onStopAllTunnels: onStopAllTunnels,
            onManageTunnels: onManageTunnels,
            dragOrigin: dragOrigin,
            onDrop: { payload in drop(payload, before: .session(session.id)) },
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .listRowSeparator(.hidden)
    }

    /// Empty-state row shared by the session list states.
    @ViewBuilder
    private func emptyStateRow(message: String, showsClearFilter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
            if showsClearFilter { EmptyView() }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var backgroundMenu: some View {
        Button(L10n.string("sidebar.newConnection", "New connection")) { startNewConnection() }
        Button(L10n.string("sidebar.newGroup", "New group…")) { beginNewGroup(forMoving: nil) }
        Divider()
        Button(L10n.string("menu.knownHosts", "Known Hosts…")) { onShowKnownHosts() }
        Button(L10n.string("menu.logins", "Logins…")) { onShowLogins() }
        Divider()
        Button(L10n.string("export.menu.all", "Export All…")) { onExport(.all) }
            .disabled(viewModel.sessions.isEmpty)
        Button(L10n.string("import.menu", "Import…")) { onImport() }
    }

    // MARK: - Row activation

    /// Applies `SessionRowActivation.build`'s answer for one input on one
    /// row, and reports whether it did anything — the row's Return handler
    /// passes that on to SwiftUI as handled/ignored, so a key press this
    /// sidebar has no use for stays available to the rest of the window.
    ///
    /// Both facts the plan needs are read here rather than in the row: the
    /// row is renaming when it is THE renaming row, and selected when it is
    /// THE selected one, and this is the scope that holds both.
    ///
    /// All four effects are handed to `performSessionRowInput`, which is the
    /// only reachable code that runs any of them: this view cannot fire an
    /// effect, cannot pass one where another belongs, and — since `apply`
    /// stopped being reachable — cannot choose which activation gets fired
    /// either. It states the input and the two facts about the row, and the
    /// answer is not its to pick.
    ///
    /// Since fix round 4 that covers the two terminal entries as well, which
    /// used to reach their callbacks straight from the row. Two things
    /// changed for them besides being unreachable from a gesture: they now
    /// move the selection onto the row they act on, and they end an open
    /// rename the way every other acting input does.
    private func activate(_ input: SessionRowInput, on session: StoredSession) -> Bool {
        guard !interactionsDisabled else { return false }
        let isRenaming = renamingID == session.id
        let isSelected = selectedSessionID == session.id
        if SidebarRenameHandoff.endsOpenRename(
            renamingID: renamingID, input: input,
            isRenaming: isRenaming, isSelected: isSelected) {
            endRename()
        }
        return performSessionRowInput(
            input, on: session, isRenaming: isRenaming, isSelected: isSelected,
            onSelect: SessionRowSelectEffect(moveSelection(to:)),
            onConnect: onConnect,
            onOpenTerminal: onOpenTerminal,
            onOpenExternalTerminal: onOpenExternalTerminal)
    }

    /// Stores a copy of one connection and points at it.
    ///
    /// Two lines, and neither of them decides anything: what the copy
    /// carries — and, the half worth naming, that it reaches no Keychain
    /// slot of the template's — is `SessionDuplication`'s answer, asked
    /// through the view model. Nothing here derives a name, a group or an
    /// identifier, for the reason this file already gives about places:
    /// a rule spelled in a menu body is one no test reaches.
    ///
    /// The selection move is what makes the entry worth having: a copy
    /// written without being pointed at is a row the user has to go find
    /// among the others. It goes through `moveSelection(to:)` so the
    /// keyboard follows the highlight, like every other selection write in
    /// this file.
    private func duplicate(_ session: StoredSession) {
        guard let copy = viewModel.duplicateSession(session) else { return }
        moveSelection(to: copy)
    }

    /// "New connection", from either of the two entries that offer it.
    ///
    /// Clears the selection BEFORE forwarding, so the highlight and the
    /// detail pane agree: the window is about to show an empty form, and a
    /// stored session left highlighted behind it would name a session that
    /// form is not about. The keyboard focus is deliberately left where it
    /// is — `focusedRowID` is SwiftUI's as much as this view's, and taking it
    /// off a row is not this entry's business.
    private func startNewConnection() {
        guard !interactionsDisabled else { return }
        selectedSessionID = nil
        onSelectSession(nil)
        onNew()
    }

    /// Puts the sidebar's selection, and the keyboard with it, on one row.
    /// The two move together everywhere: a highlight the keyboard cannot
    /// reach is the "selection no key acts on" this task exists to avoid.
    private func moveSelection(to session: StoredSession) {
        guard !interactionsDisabled else { return }
        selectedSessionID = session.id
        focusedRowID = session.id
        onSelectSession(session.id)
    }

    private func selectGroup(_ group: StoredGroup) {
        guard !interactionsDisabled, renamingID == nil else { return }
        selectedSessionID = nil
        onSelectGroup(group)
    }

    // MARK: - Inline rename

    /// Deliberately NOT routed through `endRename()` when a rename is
    /// already open on another row — this is a rename MOVING, not one
    /// ending. Of the three pieces of state `endRename` owns, two
    /// (`renamingID` and `focusedRenameID`) are reassigned in this body
    /// anyway, and the third is the one that must not run here: handing
    /// `focusedRowID` back to the selected row would fight the field this
    /// call is about to focus for the first responder. The draft on the
    /// previous row is dropped, which is what this sidebar does with any
    /// draft not committed by Return or by the menu.
    private func startRename(id: UUID, currentName: String) {
        renamingID = id
        renameDraft = currentName
        focusedRenameID = id
    }

    /// The one deliberate end of an inline rename — commit, cancel and the
    /// hand-off in `activate` all go through it.
    ///
    /// The hand-back is the part that has to be in one place (fix round 1):
    /// a rename takes the keyboard away from the row, and SwiftUI clears
    /// `focusedRowID` when the text field takes over. Without giving it back
    /// the selection stays drawn on a row that Return no longer reaches —
    /// highlight and keyboard silently pointing at different things, with
    /// nothing on screen saying so. Ends on the SELECTED row rather than the
    /// renamed one, since those can differ and the selection is what the
    /// user can see.
    private func endRename() {
        renamingID = nil
        focusedRenameID = nil
        focusedRowID = selectedSessionID
    }

    private func commitSessionRename(_ session: StoredSession) {
        guard renamingID == session.id else { return }
        let draft = renameDraft
        endRename()
        viewModel.renameSession(session, to: draft)
    }

    private func commitGroupRename(_ group: StoredGroup) {
        guard renamingID == group.id else { return }
        let draft = renameDraft
        endRename()
        viewModel.renameGroup(group, to: draft)
    }

    // MARK: - New group

    /// `parentID` nests the new group inside an existing folder — the
    /// folder-row menu's own "New group…" (Task 4, jump-and-groups plan).
    /// `nil`, the default, is what the background/toolbar entry and a
    /// session's "Move to…" submenu both still pass: a top-level group.
    private func beginNewGroup(forMoving session: StoredSession?, inGroup parentID: UUID? = nil) {
        sessionPendingGroupMove = session
        pendingNewGroupParentID = parentID
        newGroupName = ""
        isShowingNewGroupAlert = true
    }

    private func commitNewGroup() {
        defer {
            newGroupName = ""
            sessionPendingGroupMove = nil
            pendingNewGroupParentID = nil
        }
        guard let group = viewModel.createGroup(named: newGroupName, inGroup: pendingNewGroupParentID)
        else { return }
        if let session = sessionPendingGroupMove {
            viewModel.move(.session(session.id), intoGroup: group.id)
        }
        // A group created inside a collapsed folder must not vanish the
        // instant it is named (maintainer's fix-round-1 ruling, Task 4):
        // open that folder and every folder above it, the same chain
        // `SidebarVisibility` already opens for a search match
        // (`GroupTree.selfAndAncestors`), by removing them from the
        // remembered collapse set — the same write the disclosure triangle
        // itself makes (`expansion(of:expandsFolders:)` below). No rename:
        // the name was already taken by the alert, as at the top level.
        if let parentID = pendingNewGroupParentID {
            collapsedGroups.subtract(GroupTree.selfAndAncestors(of: parentID, in: viewModel.groups))
        }
    }

    // MARK: - Drag & drop

    /// A row was let go on a folder, or on the sidebar's own title: it goes
    /// inside, after whatever is already there.
    ///
    /// Both halves of the gesture are identities — which row was picked up,
    /// which folder it was let go on — and the place it ends up in is derived
    /// by `SidebarOrdering` in the same instant it is used. A payload naming
    /// no row of this sidebar (a tab dragged out of the strip, a text
    /// clipping) ends the gesture; so does a refusal, and a refusal the user
    /// can provoke on purpose — a folder into its own sub-folder — already
    /// says so on screen through `viewModel.errorMessage`, so nothing is
    /// reported a second time here.
    private func drop(_ payload: [String], intoGroup parentID: UUID?) -> Bool {
        guard let item = SidebarDragPayload.item(from: payload) else { return false }
        return viewModel.move(item, intoGroup: parentID) == nil
    }

    /// A row was let go on a connection: it takes that connection's place
    /// among its siblings, adopting its folder. Same rules as the other
    /// half of the gesture above.
    private func drop(_ payload: [String], before target: SidebarItem) -> Bool {
        guard let item = SidebarDragPayload.item(from: payload) else { return false }
        return viewModel.move(item, before: target) == nil
    }
}

/// The entries inside a "Move to…" submenu: the top level, then every
/// eligible group — `SidebarOrdering.moveTargets` decides which those are,
/// so a session row and a group row cannot each carry their own answer to
/// "eligible" and drift apart (Sidebar Polish, Task 3). Neither row's
/// submenu builds a checkmark for the current location any more, since
/// `moveTargets` excludes it outright rather than listing it disabled — the
/// same functional refusal the old hand-rolled session menu gave, stated
/// once instead of at each call site.
///
/// A free function rather than a method on either row: `SessionRow` and
/// `SidebarGroupRow` are two distinct `View` types with nothing else in
/// common, and a shared `@ViewBuilder` here is what lets both submenus read
/// the identical entries instead of two hand-written `ForEach`s that could
/// disagree about what a target looks like.
///
/// Each group is labelled with its path ("Work / Prod"), flat, in the
/// sidebar's depth-first order — not nested submenus (jump-and-groups plan,
/// Task 5). A nested menu would have to draw a folder that is not itself a
/// target (the item's current parent) as a submenu only, and a folder that
/// IS a target and also has children as both an entry and a submenu; the
/// path reads the same in this menu as in the editor's and the import's
/// pickers, which cannot nest at all.
@MainActor
@ViewBuilder
private func moveToMenuItems(
    for item: SidebarItem, currentParentID: UUID?, groups: [StoredGroup],
    onMove: @escaping (UUID?) -> Void
) -> some View {
    // Labels only: which ids are offered is `moveTargets`' answer, which
    // reads this same builder.
    let paths = Dictionary(
        GroupPickerEntries.build(groups: groups).map { ($0.id, $0.path) },
        uniquingKeysWith: { first, _ in first })
    ForEach(
        SidebarOrdering.moveTargets(for: item, currentParentID: currentParentID, in: groups),
        id: \.self
    ) { target in
        if let groupID = target, let path = paths[groupID] {
            Button(path) { onMove(groupID) }
        } else {
            Button(L10n.string("sidebar.moveTo.root", "Top level")) { onMove(nil) }
        }
    }
}

/// One folder row: its name (or the inline rename field), its drag payload,
/// its drop target, and its context menu.
///
/// A view of its own rather than a `@ViewBuilder` on the sidebar because it
/// owns one piece of state per folder — whether a drag is over THIS row —
/// which a shared builder has nowhere to put.
///
/// It renders what it is handed and decides nothing: the highlight is
/// `SidebarDropTargetPlan`'s answer, whether the sort entry appears is
/// `SidebarSortMenuPlan`'s, and where a dropped row lands is decided behind
/// `onDrop`, in Core.
private struct SidebarGroupRow: View {
    let group: StoredGroup
    let isRenaming: Bool
    @Binding var renameDraft: String
    var focusedRenameID: FocusState<UUID?>.Binding
    /// The sidebar's shared note of which row a drag is carrying — written
    /// by this row's own payload, read when a drop is targeted here.
    let dragOrigin: SidebarDragOrigin
    let sortPlan: SidebarSortMenuPlan
    /// Every group in the store, handed down for the same reason `SessionRow`
    /// carries it: `moveToMenuItems` needs the whole set to derive this
    /// folder's eligible targets and to look each target's name up by id.
    let groups: [StoredGroup]
    /// Compact sidebar mode (sidebar-polish plan, Task 2; extended to
    /// folder rows on the maintainer's dev-build report of 2026-09-05: "the
    /// compact sidebar does not reduce the spacing between the folders").
    /// `SessionRow.isCompact` carries the identical rule and the identical
    /// reasoning — see that property's own doc comment — so it is not
    /// repeated here: a plain fact handed down from `SessionSidebar`, one
    /// padding density change (`.padding(.vertical, 3)` to `1`), nothing
    /// else about the row.
    let isCompact: Bool
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onExport: () -> Void
    let onColor: (GroupColor?) -> Void
    let onSortByName: () -> Void
    /// "New group…" nested inside this folder (Task 4, jump-and-groups
    /// plan) — `beginNewGroup(forMoving:inGroup:)` with this folder's id, the
    /// parent-taking call, so the commit lands the new group here rather
    /// than at the top level.
    let onNewGroup: () -> Void
    let onDissolve: () -> Void
    /// "Move to…" (Sidebar Polish, Task 3) — the same call a drop onto
    /// another folder makes (`viewModel.move(.group(group.id),
    /// intoGroup:)`), so the menu and the gesture put a folder in the same
    /// place.
    let onMove: (UUID?) -> Void
    let onDrop: ([String]) -> Bool

    /// Whether a drag is over this row right now — the raw answer of the
    /// drop's `isTargeted:` closure, kept raw so that what it MEANS is
    /// `SidebarDropTargetPlan`'s to say.
    @State private var isDropTargeted = false

    @State private var choosingColor = false

    private var dropPlan: SidebarDropTargetPlan {
        SidebarDropTargetPlan.build(
            row: .group(group.id), isTargeted: isDropTargeted,
            dragged: dragOrigin.draggedItem)
    }

    var body: some View {
        HStack {
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused(focusedRenameID, equals: group.id)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                // Display-only uppercase (spec: folder labels are versal);
                // the stored group name keeps its original casing.
                SidebarGroupTitle(name: group.name)
            }
            Spacer(minLength: 0)
            GroupColorControl(hue: group.colorHue, color: group.color, isPresented: $choosingColor, onChange: onColor)
        }
        .padding(.vertical, isCompact ? 1 : 3)
        .padding(.horizontal, 2)
        // Both the surface and the border are `SidebarDropTargetPlan`'s
        // answer, drawn without a condition of this view's own: the answer
        // for "nothing is over this row" is a clear fill and a clear border,
        // so there is nothing to switch on here.
        .background(RoundedRectangle(cornerRadius: 6).fill(dropPlan.fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropPlan.borderColor, lineWidth: 2))
        .contentShape(Rectangle())
        .draggable(dragPayload())
        .dropDestination(for: String.self) { payload, _ in
            onDrop(payload)
        } isTargeted: { isDropTargeted = $0 }
        .contextMenu {
            Button(L10n.string("sidebar.rename", "Rename")) { onStartRename() }
            // Directly under Rename, ahead of Export/Sort/Move/Dissolve:
            // creating a group is a row of its own here, not tucked inside
            // "Move to…" the way a session's own "New group…" entry is (see
            // that row's context menu below, where it sits last inside the
            // "Move to" submenu, after a Divider) — a folder's own menu has
            // no "Move to…" submenu to nest it in when the folder is a lone
            // top-level one (see the empty-target-list gate below), so this
            // entry cannot depend on one existing.
            Button(L10n.string("sidebar.newGroup", "New group…")) { onNewGroup() }
            Button(L10n.string("export.menu.group", "Export Group…")) { onExport() }
            // Offered only where it can do something — see
            // `SidebarSortMenuPlan`; this project hides what cannot act
            // rather than greying it out.
            if sortPlan.isShown {
                Button(L10n.string("sidebar.group.sortByName", "Sort by Name")) { onSortByName() }
            }
            // A lone top-level folder with nothing else to move it into has
            // an empty target list (`SidebarOrdering.moveTargets` answers
            // `[]` — pinned in `SidebarOrderingTests.
            // aLoneTopLevelGroupHasNoMoveTargets`); drawing the Menu anyway
            // would open onto nothing, so it is gated on the same rule the
            // entries themselves come from, read here a second time before
            // the Menu is built.
            if !SidebarOrdering.moveTargets(
                for: .group(group.id), currentParentID: group.parentID, in: groups
            ).isEmpty {
                Menu(L10n.string("sidebar.moveTo", "Move to")) {
                    moveToMenuItems(
                        for: .group(group.id), currentParentID: group.parentID, groups: groups,
                        onMove: onMove)
                }
            }
            Button(L10n.string("sidebar.group.dissolve", "Dissolve group")) { onDissolve() }
        }
    }

    /// The payload a drag of this row carries — and the one moment the
    /// sidebar can learn WHICH row is being carried, because a drop
    /// destination is told only that something is over it.
    ///
    /// `draggable(_:)` takes its payload as an `@autoclosure @escaping`
    /// closure, so this runs when a drag begins rather than when the body is
    /// built. What happens if that ever stops holding is `SidebarDragOrigin`'s
    /// doc comment, and it is the reason that type has the shape it has.
    private func dragPayload() -> String {
        dragOrigin.draggedItem = .group(group.id)
        return SidebarDragPayload.text(for: .group(group.id))
    }
}

/// A single session row: dot, name (or inline rename field),
/// hover/selection/active styling, drag source, context menu.
private struct SessionRow: View {
    let session: StoredSession
    let isActive: Bool
    let isConnected: Bool
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    var focusedRenameID: FocusState<UUID?>.Binding
    /// Keyboard focus for the row itself, so its Return handler has
    /// something to fire on. Distinct from `focusedRenameID`, which belongs
    /// to the inline rename field inside this row.
    var focusedRowID: FocusState<UUID?>.Binding
    let groups: [StoredGroup]
    /// Compact sidebar mode (sidebar-polish plan, Task 2) — handed down as a
    /// plain presentation fact, so
    /// this row does not need to know a settings layer exists.
    ///
    /// Two rulings narrowed this to exactly one change (coordinator,
    /// 2026-09-04). Fix round 1: the DEFAULT (non-compact) row must not
    /// change at all — an earlier attempt drew `connectionSummary` as a
    /// second line whenever this was `false`; that line is gone,
    /// `connectionSummary` reaches the user only through
    /// `.help(connectionSummary)`, as it always did. Fix round 2: the
    /// protocol badge (`Text(kindBadgeLabel)`) — "how a row reads its
    /// backend at a glance" — stays visible in BOTH densities; an earlier
    /// attempt hid it behind `if !isCompact`, which the ruling reversed as
    /// making compact rows ambiguous. So: `false` (the default) is the row
    /// exactly as it was before this setting existed — one line, badge
    /// shown, `.padding(.vertical, 5)`. `true` changes exactly the
    /// padding, to `.padding(.vertical, 2)` — nothing else. No ordering,
    /// no selection behaviour, no keyboard handling changes either way —
    /// `onInput`/`SessionRowActivation` are untouched by this flag.
    let isCompact: Bool
    let onInput: (SessionRowInput, StoredSession) -> Bool
    let onEdit: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onMove: (UUID?) -> Void
    let onRequestNewGroupMove: () -> Void
    /// "Duplicate" — stores a copy of this connection and selects it.
    ///
    /// A plain callback rather than an input routed through `onInput`, and
    /// the rule for that split is what the entry DOES: duplicating writes a
    /// record and reaches no host, so a stray click costs an unused row
    /// rather than a login attempt on someone's server. Same category as
    /// `onEdit`, `onExport` and `onRequestDelete`.
    let onDuplicate: () -> Void
    let onRequestDelete: () -> Void
    let onExport: () -> Void
    let onShowAuditLog: () -> Void
    let onDiagnose: () -> Void
    /// The app-wide forwardings, read by `tunnelPlan` below. The row asks
    /// the plan what to draw and decides nothing about visibility itself.
    let tunnels: TunnelManager
    let onStartTunnel: SessionRowStartTunnelEffect<TunnelProfile>
    let onStopTunnel: (TunnelProfile) -> Void
    let onStartAllTunnels: SessionRowStartAllTunnelsEffect<StoredSession>
    let onStopAllTunnels: (StoredSession) -> Void
    let onManageTunnels: (StoredSession) -> Void
    /// The sidebar's shared note of which row a drag is carrying — written
    /// by this row's own payload, read when a drop is targeted here.
    let dragOrigin: SidebarDragOrigin
    /// A row was let go on this one. What that does — it takes this row's
    /// place among its siblings — is decided in Core behind this closure;
    /// this row supplies neither a place nor a rule.
    let onDrop: ([String]) -> Bool

    @State private var isHovering = false
    /// Whether a drag is over this row right now — the raw answer of the
    /// drop's `isTargeted:` closure, kept raw so that what it MEANS is
    /// `SidebarDropTargetPlan`'s to say.
    @State private var isDropTargeted = false

    private var dropPlan: SidebarDropTargetPlan {
        SidebarDropTargetPlan.build(
            row: .session(session.id), isTargeted: isDropTargeted,
            dragged: dragOrigin.draggedItem)
    }

    /// "SCP"/"S3" (M12/T7b), localized through the backend descriptor —
    /// never hand-picked here, so a future third `ConnectionKind` only needs
    /// a new `BackendDescriptor` case, not a change at every badge site.
    private var kindBadgeLabel: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    private var terminalPlan: SessionRowTerminalMenuPlan {
        SessionRowTerminalMenuPlan.build(for: session.kind)
    }

    /// The two terminal entries' titles, hoisted out of their `Button`
    /// lines. Every other entry in this menu spells its `L10n.string` call
    /// inline; these two cannot, because their line has to carry the input
    /// they forward as well, and `SessionRowActivationWiringTests`' Guard A
    /// reads a handler and its input on ONE line — it fails closed on a
    /// handler split across lines, deliberately.
    private var openTerminalTitle: String {
        L10n.string("sidebar.openTerminal", "Open Terminal")
    }

    private var externalTerminalTitle: String {
        L10n.string("sidebar.openExternalTerminal", "Open in External Terminal")
    }

    /// The row's background — which of the reasons to draw one wins and
    /// which colour that is are both `SessionRowHighlight`'s, so this view
    /// decides nothing about its own highlight.
    private var highlightFill: Color {
        SessionRowHighlight.build(
            isActive: isActive, isSelected: isSelected, isHovering: isHovering).fill
    }

    /// What this row's "Port forwarding" submenu offers — the whole
    /// decision, this session's profiles and their states included, is
    /// `SessionRowTunnelMenuPlan.build`'s. Whether a row may carry a
    /// forwarding at all is decided there and nowhere in this view.
    private var tunnelPlan: SessionRowTunnelMenuPlan {
        SessionRowTunnelMenuPlan.build(
            for: session, profiles: tunnels.profiles(for: session.id),
            state: { tunnels.state(of: $0) })
    }

    /// This session's forwardings, as states — the one reading both the
    /// glyph and its tooltip are derived from, so the mark and the sentence
    /// beside it cannot describe two different moments.
    private var tunnelStates: [TunnelState] {
        tunnels.profiles(for: session.id).map {
            TunnelPresentationState.sessionSummary(profile: $0, state: tunnels.state(of: $0.id))
        }
    }

    /// What the row draws for its forwardings, or `nil` when it draws
    /// nothing. The whole decision — including "no glyph when the session
    /// has no profile" — is `TunnelGlyphPlan`'s; this view picks no colour
    /// and counts nothing itself.
    private var tunnelGlyph: TunnelGlyphPlan.Glyph? {
        TunnelGlyphPlan.glyph(states: tunnelStates)
    }

    /// The tooltip: the worst state's own tooltip text, which for a failure
    /// is its kind in the app's language and for an active forwarding that
    /// is failing connections adds the last one's kind. Mapping it again
    /// here would put a second spelling of the same finding in the app — the
    /// same rule the profile sheet's state column follows, through the same
    /// `stateTooltip`.
    private var tunnelTooltip: String {
        let worst = TunnelManager.Aggregate.of(tunnelStates).worst ?? .stopped
        return String(
            format: L10n.string("tunnel.glyph.tooltip %@", "Port forwarding: %@"),
            TunnelProfilesSheet.stateTooltip(worst))
    }

    /// The backend's own `displaySummary` (M22/T11) — NOT the old hand-rolled
    /// "\(session.username)@\(session.host):\(session.port)", which read
    /// SSH-shaped fields S3 and WebDAV never fill. Historical now: a session
    /// written before M23 carried the `"unused"` placeholder in its flat
    /// host/username columns (so the tooltip read "unused@unused:22"), and
    /// one written between M23 and M26 read blank through `StoredSession`'s
    /// SSH-fallback accessors (so it would read "@:22") — accessors M26
    /// deleted. Neither was a connection summary, and `StoredSession` has had
    /// no host/username accessor to read at all since.
    private var connectionSummary: String {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        return descriptor.displaySummary(descriptor.sessionValues(session))
    }

    var body: some View {
        HStack(spacing: 6) {
            SessionSidebarIdentity(appearance: session.appearance ?? .init(), kind: session.kind, isConnected: isConnected)

            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused(focusedRenameID, equals: session.id)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(session.name)
                    .lineLimit(1)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? DesignTokens.remoteBlue : Color.primary)
            }

            Spacer(minLength: 0)

            // Protocol badge (M12/T7b): "SCP"/"S3" from the backend
            // descriptor — unobtrusive, same small-label typography as the
            // sidebar's own section headers above. KEPT in both densities
            // (sidebar-polish plan, Task 2, fix round 2, coordinator
            // ruling 2026-09-04): it is how a row reads its backend at a
            // glance, and hiding it would make a compact row ambiguous.
            // Compact mode is the padding change alone — see `isCompact`.
            Text(kindBadgeLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignTokens.inkTertiary)
                .fixedSize(horizontal: true, vertical: false)

            // Port-forwarding glyph (port-forwarding plan, Task 7). Drawn in
            // BOTH densities, for the same reason the protocol badge above
            // it is: compact mode is the padding change alone, and a row
            // that hid whether its forwardings were up would be hiding the
            // one thing about them that is visible without a menu.
            //
            // Colour is never the only channel: the symbol says whether
            // this is a forwarding or a warning about one, and the text
            // beside it says how many are up, how many connections failed
            // in a row, or `!`. Both come from `tunnelGlyph`; this view
            // chooses neither, and since fix round 1 (2026-09-20) that is
            // true of the symbol as well — it used to be spelled here.
            // The status count precedes the icon so the icon stays at the
            // trailing edge. No empty tunnel column pushes the badge inward.
            if let glyph = tunnelGlyph {
                HStack(spacing: 2) {
                    if let text = glyph.text {
                        Text(text).font(.system(size: 10, weight: .semibold))
                    }
                    if glyph.symbol == TunnelSymbols.tunnel {
                        TunnelIcon(size: 12)
                    } else {
                        Image(systemName: glyph.symbol)
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(glyph.tint.color)
                .help(tunnelTooltip)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isCompact ? 2 : 5)
        .padding(.horizontal, 4)
        // Two surfaces, stacked rather than chosen between: the drop
        // target's is drawn in front and is `Color.clear` whenever nothing
        // is over this row (`SidebarDropTargetPlan.none`), so no condition
        // here decides which of the two wins. The border is the second
        // channel, drawn unconditionally and clear for the same case.
        .background(RoundedRectangle(cornerRadius: 6).fill(dropPlan.fill))
        .background(RoundedRectangle(cornerRadius: 6).fill(highlightFill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropPlan.borderColor, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { _ = onInput(.doubleClick, session) }
        .onTapGesture(count: 1) { _ = onInput(.singleClick, session) }
        // Focusable only while it is not being renamed: the inline rename
        // field inside this row owns the keyboard while it is up, and a
        // focusable row around it would compete for Return with the field
        // that is being edited.
        .focusable(!isRenaming)
        // The selection background is this row's focus indicator; a
        // second, system-drawn ring on top of it would read as two
        // different marks for one state.
        .focusEffectDisabled()
        .focused(focusedRowID, equals: session.id)
        .onKeyPress(.return) { onInput(.returnKey, session) ? .handled : .ignored }
        .onHover { isHovering = $0 }
        // Reordering by dragging, in two halves: this row carries its own
        // identity, and a row dropped on this one takes this one's place.
        // No position travels either way — see `SidebarDragPayload` for what
        // the payload says and `SidebarOrdering` for who derives the place.
        .draggable(dragPayload())
        .dropDestination(for: String.self) { payload, _ in
            onDrop(payload)
        } isTargeted: { isDropTargeted = $0 }
        .contextMenu {
            Button(L10n.string("sidebar.connect", "Connect")) { _ = onInput(.contextMenuEntry, session) }
            // The two terminal entries (P3c/T2), directly under "Connect"
            // because that is what they are: "Open Terminal" IS a connect
            // and differs only in which half of the window comes up, and
            // "Open in External Terminal" is the same host reached another
            // way. Whether they appear at all is `terminalPlan`'s decision,
            // not this `if`'s — see `SessionRowTerminalMenuPlan`.
            //
            // Both forward an input rather than calling a callback (fix
            // round 4): each starts a session on the user's host, which
            // makes them exactly as dangerous on a stray click as
            // "Connect", and the row holds nothing they could be called
            // through any more.
            if terminalPlan.isShown {
                Button(openTerminalTitle) { _ = onInput(.terminalMenuEntry, session) }
                Button(externalTerminalTitle) { _ = onInput(.externalTerminalMenuEntry, session) }
            }
            Button(L10n.string("sidebar.edit", "Edit…")) { onEdit() }
            Button(L10n.string("export.menu.single", "Export…")) { onExport() }
            Button(L10n.string("sidebar.rename", "Rename")) { onStartRename() }
            // Directly under Rename, in the menu that also holds Delete —
            // where the design puts it, among the entries that act on the
            // stored record rather than on what it connects to. No gate: a
            // stored connection can always be copied, and this project hides
            // what cannot act instead of greying it out, so there is nothing
            // here to hide either.
            Button(L10n.string("sidebar.duplicate", "Duplicate")) { onDuplicate() }
            Menu(L10n.string("sidebar.moveTo", "Move to")) {
                moveToMenuItems(
                    for: .session(session.id), currentParentID: session.groupID, groups: groups,
                    onMove: onMove)
                Divider()
                Button(L10n.string("sidebar.newGroup", "New group…")) { onRequestNewGroupMove() }
            }
            Divider()
            Button(L10n.string("sidebar.auditLog", "Audit Log…")) { onShowAuditLog() }
            // Under the audit log, in the group of entries that ask
            // this connection a question rather than change it. No
            // gate: the panel opens for a connection that has never
            // been dialled — that is exactly the case it is for — and
            // opening it puts nothing on anyone's host.
            Button(L10n.string("diagnostics.menu", "Diagnose…")) { onDiagnose() }
            // "Port forwarding" submenu (port-forwarding plan, Task 6),
            // under the two entries that ask this connection a question,
            // because it is the third: a forwarding is opened against the
            // stored session without a tab of its own. Whether it appears at
            // all is `tunnelPlan`'s answer — a session that cannot carry a
            // forwarding (not SSH, a jump host, a login set) gets no
            // submenu rather than a greyed one, which is what this project
            // does with what cannot act.
            //
            // The per-profile entry toggles: checked means running, and a
            // click stops it; unchecked starts it, including after a
            // failure (the state table allows `.failed → .start`). Starting
            // reaches the user's host, so it goes through an effect value
            // and `SessionRowTunnelActivation`; stopping does not, so it is
            // a plain callback.
            if case .shown(let tunnelEntries) = tunnelPlan {
                Menu(L10n.string("tunnel.menu", "Port forwarding")) {
                    ForEach(tunnelEntries) { entry in
                        Button {
                            if entry.isRunning {
                                onStopTunnel(entry.profile)
                            } else {
                                SessionRowTunnelActivation.start(
                                    profile: entry.profile, using: onStartTunnel)
                            }
                        } label: {
                            // The glyph carries the state, never a colour on
                            // its own: a filled check for running, an empty
                            // circle for not.
                            Label(
                                entry.profile.name,
                                systemImage: entry.isRunning ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    if !tunnelEntries.isEmpty {
                        Divider()
                        Button(L10n.string("tunnel.menu.startAll", "Start all")) {
                            SessionRowTunnelActivation.startAll(
                                for: session, using: onStartAllTunnels)
                        }
                        Button(L10n.string("tunnel.menu.stopAll", "Stop all")) {
                            onStopAllTunnels(session)
                        }
                        Divider()
                    }
                    Button(L10n.string("tunnel.menu.manage", "Manage forwardings…")) {
                        onManageTunnels(session)
                    }
                }
            }
            Divider()
            Button(L10n.string("sidebar.delete", "Delete"), role: .destructive) {
                onRequestDelete()
            }
        }
        // Pure data interpolation, backend-specific (user@host for SSH,
        // bucket @ endpoint-host for S3, user @ host for WebDAV) — no
        // natural-language words to translate, identical in every locale.
        .help(connectionSummary)
    }

    /// The payload a drag of this row carries — and the one moment the
    /// sidebar can learn WHICH row is being carried, because a drop
    /// destination is told only that something is over it. Same shape, and
    /// the same `@autoclosure` reasoning, as `SidebarGroupRow`'s.
    private func dragPayload() -> String {
        dragOrigin.draggedItem = .session(session.id)
        return SidebarDragPayload.text(for: .session(session.id))
    }
}
