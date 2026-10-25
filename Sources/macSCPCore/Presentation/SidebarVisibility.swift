import Foundation

public struct SidebarVisibility: Equatable, Sendable {
    /// Distinguishes "there is nothing to show because the store is empty"
    /// from "there is nothing to show because the search matched nothing". The sidebar needs
    /// different copy for each (an empty store invites creating a session; a
    /// filter matching nothing invites clearing it), and deliberately not
    /// copy per CAUSE: one message that names no specific filter is true
    /// whichever of them emptied the list, and the sidebar offers one way
    /// back from all of them.
    public enum Emptiness: Equatable, Sendable {
        case notEmpty
        case noSessionsAtAll
        case filterMatchesNothing
    }

    /// Everything that survived the filter, still carrying its nesting and
    /// its positions. Read through `children(of:)`, `session(_:)` and
    /// `group(_:)` rather than directly: those are the three questions a
    /// sidebar has, and going around them is how a view starts deriving an
    /// order of its own.
    public let visibleTree: SidebarOrdering.Tree
    /// Whether the sidebar's "IMPORTED" section (unsaved `SSHConfigHost`
    /// entries) should render at all: nothing is narrowing the list —
    /// no search — AND `importedHostsCount > 0` (an
    /// empty section has nothing to draw either way).
    ///
    /// One reason covers both narrowings: an imported host is not a
    /// `StoredSession`, so it carries no name this filter
    /// ever examines, and rendering an unfilterable section next to filtered
    /// ones would misrepresent the filter as covering everything on screen.
    public let showsImportedSection: Bool
    public let emptiness: Emptiness
    /// Whether every folder draws OPEN regardless of what the user collapsed
    /// (D3): true exactly while a search is narrowing the tree.
    ///
    /// Nesting is what makes this necessary — a match inside a closed folder
    /// passes the filter and is still invisible, so one filters on something
    /// one cannot see. It is a fact about what the sidebar SHOWS, which is
    /// why it is answered here; what it does to the remembered collapse state
    /// (nothing — it overlays it, never writes it) is
    /// `SidebarFolderDisclosure`'s half.
    ///
    public let expandsFolders: Bool

    public init(
        visibleTree: SidebarOrdering.Tree,
        showsImportedSection: Bool,
        emptiness: Emptiness,
        expandsFolders: Bool
    ) {
        self.visibleTree = visibleTree
        self.showsImportedSection = showsImportedSection
        self.emptiness = emptiness
        self.expandsFolders = expandsFolders
    }

    /// The rows to draw directly under one folder (`nil` = the top level), in
    /// display order.
    ///
    /// Names determine display order at every level. Legacy placement
    /// ranks remain in the snapshot but do not override alphabetical order.
    public func children(of parentID: UUID?) -> [SidebarItem] {
        SidebarOrdering.alphabeticalChildren(of: parentID, in: visibleTree)
    }

    /// The connection one row names, or `nil` when the filter removed it.
    /// Answers from the same snapshot `children(of:)` walks, so a row handed
    /// out by one of these calls always resolves through the others.
    public func session(_ id: UUID) -> StoredSession? {
        visibleTree.sessions.first { $0.id == id }
    }

    /// The folder one row names, under the same rule as `session(_:)`.
    public func group(_ id: UUID) -> StoredGroup? {
        visibleTree.groups.first { $0.id == id }
    }

    /// Computes what the sidebar shows for `sessions`/`groups` under
    /// the optional search, given `importedHostsCount` unsaved `SSHConfigHost`
    /// entries currently available to import (the sidebar's "IMPORTED"
    /// section — `SSHConfigHost` lives outside `StoredSession`, so only its
    /// count crosses into this decision, not the hosts themselves).
    ///
    /// With no search, every session and folder shows — including one with nothing in it, because a folder is a thing
    /// the user made, so a freshly created one is present before anything is
    /// in it, and one whose last session was just dragged out stays present —
    /// and the imported section shows whenever `importedHostsCount > 0`.
    ///
    /// A session matches when the predicate matches its NAME or the
    /// backend's own `displaySummary` — which is where a session's host and
    /// user name live since `StoredSession` stopped carrying flat SSH
    /// columns, and which is the same one-line identity the sidebar row's
    /// tooltip and the audit trail show. What that line contains is each
    /// backend's answer, not this type's: SSH spells `user@host`, while S3
    /// spells its bucket and endpoint host and names no user at all.
    ///
    /// A FOLDER NAME is never a match. A folder is on screen because
    /// something in it matched; matching the folder itself would put its
    /// whole contents on screen and claim hits that are not there.
    ///
    /// `nil` and a predicate that matches everything mean the same thing here
    /// — no search — and the second spelling is load-bearing: the App layer
    /// answers a matches-everything predicate for an INVALID regular
    /// expression, so a half-typed pattern shows its error beside a sidebar
    /// that goes on drawing what it drew. An empty sidebar from a stray `(`
    /// would look like data loss. For the same reason an invalid pattern also
    /// leaves `expandsFolders` false: nothing is being narrowed, so there is
    /// nothing to unfold for.
    ///
    /// A search hides the imported section: an unfilterable section drawn beside filtered ones presents the
    /// filter as covering everything on screen.
    ///
    /// **A folder survives a filter when anything BELOW it matches**, not
    /// when its own sessions do. Nesting is what forces that: with the match
    /// two levels down, neither folder on the way to it carries a matching
    /// session, so dropping a folder for having none of its own takes the
    /// match off screen with it — the connection is in the store, passes the
    /// filter, and is reachable by no route at all. The chain is kept alive
    /// by walking upward from each match (`GroupTree.selfAndAncestors`),
    /// which is also why an ancestor can never be dropped while a descendant
    /// stays: the walk keeps both or neither.
    ///
    /// `emptiness` is `.notEmpty` whenever the top level has a row to draw or
    /// the imported section does. Otherwise — nothing anywhere — it is
    /// `.noSessionsAtAll` when `sessions` itself was empty, or
    /// `.filterMatchesNothing` when it was not (an active filter, or a
    /// dangling `groupID` naming no group in `groups`, consumed everything
    /// that would otherwise have drawn).
    public static func compute(
        sessions: [StoredSession],
        groups: [StoredGroup],
        importedHostsCount: Int,
        search: FileSearch.FileSearchPredicate?
    ) -> SidebarVisibility {
        // A predicate that matches everything is not a search — see this
        // method's doc comment for why that spelling has to keep meaning
        // "nothing is being filtered".
        let searching = search.map { !$0.isEmpty } ?? false

        func matchesSearch(_ session: StoredSession) -> Bool {
            guard searching, let search else { return true }
            if search.matches(session.name) { return true }
            let descriptor = BackendDescriptor.descriptor(for: session.kind)
            return search.matches(descriptor.displaySummary(descriptor.sessionValues(session)))
        }

        let visibleSessions = sessions.filter(matchesSearch)
        let visibleGroups: [StoredGroup]
        if !searching {
            visibleGroups = groups
        } else {
            var reachable: Set<UUID> = []
            for session in visibleSessions {
                guard let groupID = session.groupID else { continue }
                reachable.formUnion(GroupTree.selfAndAncestors(of: groupID, in: groups))
            }
            visibleGroups = groups.filter { reachable.contains($0.id) }
        }

        let visibleTree = SidebarOrdering.Tree(groups: visibleGroups, sessions: visibleSessions)
        let showsImportedSection = !searching && importedHostsCount > 0

        // Structural, not incidental: this is the actual "is there anything
        // to draw" question, asked of the level the sidebar starts drawing at
        // rather than inferred from `visibleSessions.isEmpty` — which would
        // say `.notEmpty` for a session whose `groupID` names no group in
        // `groups` even though such a session hangs off a parent that draws
        // nowhere and is therefore never asked for.
        let hasAnythingToDraw =
            !SidebarOrdering.children(of: nil, in: visibleTree).isEmpty || showsImportedSection

        let emptiness: Emptiness
        if hasAnythingToDraw {
            emptiness = .notEmpty
        } else {
            emptiness = sessions.isEmpty ? .noSessionsAtAll : .filterMatchesNothing
        }

        return SidebarVisibility(
            visibleTree: visibleTree,
            showsImportedSection: showsImportedSection,
            emptiness: emptiness,
            expandsFolders: searching
        )
    }

}
