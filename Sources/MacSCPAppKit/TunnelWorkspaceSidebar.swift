import SwiftUI
import macSCPCore

enum TunnelWorkspaceSelection: Hashable {
    case all, ungrouped, group(UUID), profile(UUID)
}

enum TunnelCatalog {
    /// Generated names append the listen port. Compact presentation strips
    /// only that exact suffix; the saved name and custom text stay untouched.
    static func sidebarName(_ profile: TunnelProfile, compact: Bool) -> String {
        guard compact else { return profile.name }
        let suffix = " · \(TunnelEndpoints.listener(profile).port)"
        guard profile.name.hasSuffix(suffix) else { return profile.name }
        let name = String(profile.name.dropLast(suffix.count))
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? profile.name : name
    }

    static func profiles(selection: TunnelWorkspaceSelection, profiles: [TunnelProfile], groups: [TunnelGroup]) -> [TunnelProfile] {
        let profiles = DisplayNameOrder.sorted(profiles, by: \.name)
        switch selection {
        case .all: return profiles
        case .group(let id):
            let scope = TunnelGroup.subtree(id, in: groups)
            return profiles.filter { $0.groupID.map(scope.contains) == true }
        case .profile(let id): return profiles.filter { $0.id == id }
        case .ungrouped:
            let known = Set(groups.map(\.id))
            return profiles.filter { $0.groupID.map { !known.contains($0) } ?? true }
        }
    }

    static func groupError(_ error: any Error) -> String {
        switch error as? TunnelGroupError {
        case .emptyName: return L10n.string("tunnels.group.nameRequired", "Enter a group name.")
        case .duplicateName: return L10n.string("tunnels.group.duplicate", "A group with this name already exists.")
        case .missingGroup: return L10n.string("tunnels.group.missing", "This group no longer exists. Choose another group.")
        case .invalidParent: return L10n.string("tunnels.group.invalidParent", "A group cannot be placed inside itself or one of its subgroups.")
        case nil: return error.localizedDescription
        }
    }

    struct GroupRow: Identifiable, Equatable {
        let group: TunnelGroup
        let depth: Int
        var id: UUID { group.id }
    }

    enum SidebarRow: Identifiable, Equatable {
        case group(GroupRow)
        case profile(TunnelProfile, depth: Int)
        var id: UUID {
            switch self {
            case .group(let row): row.id
            case .profile(let profile, _): profile.id
            }
        }
    }

    /// At each level, render alphabetical tunnels before alphabetical folders.
    /// A collapsed folder hides both its direct tunnels and its descendants.
    static func sidebarRows(groups: [TunnelGroup], profiles: [TunnelProfile], collapsed: Set<UUID>, hiddenEntries: Set<UUID> = []) -> [SidebarRow] {
        let orderedProfiles = DisplayNameOrder.sorted(profiles, by: \.name)
        var result = Self.profiles(selection: .ungrouped, profiles: orderedProfiles, groups: groups)
            .map { SidebarRow.profile($0, depth: 0) }
        for row in rows(groups: groups, collapsed: collapsed) {
            result.append(.group(row))
            if !collapsed.contains(row.id), !hiddenEntries.contains(row.id) {
                result += orderedProfiles.filter { $0.groupID == row.id }
                    .map { .profile($0, depth: row.depth + 1) }
            }
        }
        return result
    }

    /// Flatten the visible tree so nested folders do not introduce extra row padding.
    static func rows(groups: [TunnelGroup], collapsed: Set<UUID>) -> [GroupRow] {
        let groups = DisplayNameOrder.sorted(groups, by: \.name)
        let known = Set(groups.map(\.id))
        var visited: Set<UUID> = []
        var result: [GroupRow] = []
        func visit(_ group: TunnelGroup, depth: Int) {
            guard visited.insert(group.id).inserted else { return }
            result.append(GroupRow(group: group, depth: depth))
            if collapsed.contains(group.id) { return }
            for child in groups where child.parentID == group.id { visit(child, depth: depth + 1) }
        }
        for group in groups where group.parentID.map({ !known.contains($0) }) ?? true {
            visit(group, depth: 0)
        }
        return result
    }
}

/// Navigation is window-local; groups and runner state remain process-wide.
struct TunnelWorkspaceSidebar: View {
    let manager: TunnelManager
    var sessions: [StoredSession] = []
    var selection: Binding<TunnelWorkspaceSelection> = .constant(.all)
    var decider: HostKeyDecider = .refusing
    var sidebarCompact = false
    let onSessions: () -> Void
    var onSettings: () -> Void = {}
    var onNewTunnel: () -> Void = {}
    @State private var collapsed: Set<UUID> = []
    @State private var groupsWithHiddenEntries: Set<UUID> = []
    @State private var ungroupedCollapsed = false
    @State private var editingGroup: GroupEditorItem?
    @State private var deletingGroup: TunnelGroup?
    @State private var errorMessage: String?
    @State private var choosingGroupColor: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarWorkspaceHeading(title: L10n.string("workspace.tunnels", "Tunnels"))
            SidebarList {
                    Button { selection.wrappedValue = .all } label: {
                        SidebarNavigationLabel(title: L10n.string("tunnels.pool", "All tunnels"), symbol: "apple.health.trends")
                    }
                    .help(L10n.string("tunnels.pool", "All tunnels"))
                    .listRowBackground(selection.wrappedValue == .all ? DesignTokens.remoteBlue.opacity(0.12) : .clear)
                    Button {
                        onNewTunnel()
                    } label: {
                        SidebarNavigationLabel(title: L10n.string("tunnels.new", "New tunnel…"), symbol: "plus.rectangle.on.rectangle")
                    }
                    .help(L10n.string("tunnels.new", "New tunnel…"))
                    Divider()
                    let rows = TunnelCatalog.sidebarRows(groups: manager.allGroups, profiles: manager.allProfiles, collapsed: collapsed, hiddenEntries: groupsWithHiddenEntries)
                    let bands = SidebarGroupBands.tunnels(rows, groups: manager.allGroups)
                    ForEach(rows) { entry in
                        switch entry {
                        case .group(let row):
                            groupSection(row.group, depth: row.depth)
                                .modifier(SidebarGroupForeground(layers: bands[entry.id] ?? []))
                                .padding(.top, row.depth == 0 ? 8 : 2)
                                .padding(.bottom, SidebarGroupBands.headerBottomInset(for: bands[entry.id] ?? []))
                                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                                .listRowBackground(SidebarGroupBandBackground(layers: bands[entry.id] ?? []))
                        case .profile(let profile, let depth):
                            tunnelRow(profile)
                                .modifier(SidebarGroupForeground(layers: bands[entry.id] ?? []))
                                .padding(.leading, SidebarIndentation.leading(depth: depth))
                                .padding(.trailing, SidebarIndentation.leading(depth: depth))
                                .padding(.bottom, SidebarGroupBands.bottomContentInset(for: bands[entry.id] ?? []))
                                .listRowBackground(SidebarGroupBandBackground(layers: bands[entry.id] ?? []))
                        }
                    }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(L10n.string("tunnels.new", "New tunnel…"), action: onNewTunnel)
                Button(L10n.string("tunnels.group.new", "New group…")) {
                    editingGroup = GroupEditorItem(group: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.sidebarSurface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SessionSidebarToolbar(showsTunnels: true, onSessions: onSessions, onSettings: onSettings,
                groupsAvailable: !manager.allGroups.isEmpty,
                onCollapseGroups: {
                    groupsWithHiddenEntries = Set(manager.allGroups.map(\.id))
                    let parents = Set(manager.allGroups.compactMap(\.parentID))
                    collapsed = groupsWithHiddenEntries.subtracting(parents)
                },
                onExpandGroups: { collapsed.removeAll(); groupsWithHiddenEntries.removeAll() })
        }
        .sheet(item: $editingGroup) { item in
            TunnelGroupEditor(group: item.group, parentID: item.parentID, manager: manager) { id in
                selection.wrappedValue = .group(id)
                editingGroup = nil
            } onCancel: { editingGroup = nil }
        }
        .confirmationDialog(L10n.string("tunnels.group.dissolveConfirm", "Dissolve this group? Its tunnels will be kept and become ungrouped. Its subgroups will move up one level. No tunnel will be stopped."),
                            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
            Button(L10n.string("sidebar.group.dissolve", "Dissolve group")) {
                guard let group = deletingGroup else { return }
                do {
                    try manager.removeGroup(group)
                    if selection.wrappedValue == .group(group.id) { selection.wrappedValue = .ungrouped }
                } catch { errorMessage = TunnelCatalog.groupError(error) }
                deletingGroup = nil
            }
        }
        .alert(L10n.string("tunnels.group.error", "Group could not be saved"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.string("common.ok", "OK")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func groupSection(_ group: TunnelGroup, depth: Int) -> some View {
            SidebarGroupHeader(isExpanded: Binding(
                get: { !collapsed.contains(group.id) },
                set: { if $0 { collapsed.remove(group.id); groupsWithHiddenEntries.remove(group.id) } else { collapsed.insert(group.id) } }),
                name: group.name, isSelected: selection.wrappedValue == .group(group.id)) {
                Button { selection.wrappedValue = .group(group.id) } label: {
                    SidebarGroupTitle(name: group.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2).padding(.vertical, 1)
                        .contentShape(Rectangle())
                }
                .help(group.name)
                if !sidebarCompact {
                    GroupColorControl(hue: group.colorHue, color: group.color, isPresented: Binding(
                        get: { choosingGroupColor == group.id },
                        set: { choosingGroupColor = $0 ? group.id : nil })) { hue in
                        setColor(hue, for: group)
                    }
                }
            }
            .contextMenu {
                Button(L10n.string("tunnels.group.start", "Start group")) { Task { await manager.startGroup(group.id, decider: decider) } }
                Button(L10n.string("tunnels.group.stop", "Stop group")) { Task { await manager.stopGroup(group.id) } }
                Divider()
                Button(L10n.string("sidebar.newGroup", "New group…")) {
                    editingGroup = GroupEditorItem(group: nil, parentID: group.id)
                    collapsed.remove(group.id)
                }
                Button(L10n.string("sidebar.rename", "Rename")) { editingGroup = GroupEditorItem(group: group) }
                Menu(L10n.string("sidebar.moveTo", "Move to")) {
                    Button(L10n.string("sidebar.moveTo.root", "Top level")) { moveGroup(group, to: nil) }
                        .disabled(group.parentID == nil)
                    let excluded = TunnelGroup.subtree(group.id, in: manager.allGroups)
                    ForEach(manager.allGroups.filter { !excluded.contains($0.id) }) { parent in
                        Button(TunnelGroup.path(parent, in: manager.allGroups)) { moveGroup(group, to: parent.id) }
                            .disabled(group.parentID == parent.id)
                    }
                }
                Button(L10n.string("sidebar.group.dissolve", "Dissolve group")) { deletingGroup = group }
            }
        .padding(.leading, SidebarIndentation.leading(depth: depth))
    }

    private func setColor(_ color: GroupColor?, for group: TunnelGroup) {
        var updated = group
        updated.colorHue = nil
        updated.color = color
        do { try manager.saveGroup(updated) }
        catch { errorMessage = TunnelCatalog.groupError(error) }
    }

    private func tunnelRow(_ profile: TunnelProfile) -> some View {
        let state = manager.state(of: profile.id)
        return Button { selection.wrappedValue = .profile(profile.id) } label: {
            HStack(spacing: 6) {
                TunnelServiceIcon(appearance: profile.appearance, size: 14)
                    .overlay(alignment: .bottomTrailing) {
                        if !sidebarCompact {
                            Circle().fill(tint(state))
                                .frame(width: DesignTokens.sidebarStatusDotSize,
                                       height: DesignTokens.sidebarStatusDotSize)
                                .overlay { Circle().stroke(DesignTokens.sidebarSurface, lineWidth: 1) }
                                .offset(x: 2, y: 2)
                        }
                    }
                Text(TunnelCatalog.sidebarName(profile, compact: sidebarCompact)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.vertical, sidebarCompact ? 2 : 5)
            .contentShape(Rectangle())
            .background(selection.wrappedValue == .profile(profile.id) ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .help(profile.name + "\n" + TunnelProfilesSheet.stateTooltip(state))
        .modifier(TunnelProfileActions(profile: profile, sessions: sessions, manager: manager, decider: decider))
    }

    private func move(_ profile: TunnelProfile, to id: UUID?) {
        do { try manager.move(profile, to: id) }
        catch { errorMessage = TunnelCatalog.groupError(error) }
    }

    private func moveGroup(_ group: TunnelGroup, to id: UUID?) {
        var moved = group
        moved.parentID = id
        do { try manager.saveGroup(moved) }
        catch { errorMessage = TunnelCatalog.groupError(error) }
    }

    private func disclosure(expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 16, height: 22).contentShape(Rectangle())
        }
        .help(L10n.string("tunnels.group.disclosure", "Expand or collapse group"))
    }

    private func tint(_ state: TunnelState) -> Color {
        switch state {
        case .stopped: return .secondary
        case .active: return state.isDegraded ? .orange : .green
        case .failed: return .red
        case .connecting, .reconnecting, .needsConfirmation: return .orange
        }
    }
}

private struct GroupEditorItem: Identifiable {
    let id = UUID()
    let group: TunnelGroup?
    var parentID: UUID? = nil
}

private struct TunnelGroupEditor: View {
    let group: TunnelGroup?
    let parentID: UUID?
    let manager: TunnelManager
    let onSave: (UUID) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var selectedParentID: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group == nil ? L10n.string("tunnels.group.new", "New group…") : L10n.string("tunnels.group.rename", "Rename group…"))
                .font(.headline)
            TextField(L10n.string("tunnels.group.name", "Group name"), text: $name).textFieldStyle(.roundedBorder)
            Picker(L10n.string("tunnels.group.parent", "Parent group"), selection: $selectedParentID) {
                Text(L10n.string("sidebar.moveTo.root", "Top level")).tag(nil as UUID?)
                let excluded = group.map { TunnelGroup.subtree($0.id, in: manager.allGroups) } ?? []
                ForEach(manager.allGroups.filter { !excluded.contains($0.id) }) { parent in
                    Text(TunnelGroup.path(parent, in: manager.allGroups)).tag(Optional(parent.id))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.string("common.save", "Save")) {
                    let value = TunnelGroup(id: group?.id ?? UUID(), name: name, parentID: selectedParentID, colorHue: group?.colorHue, color: group?.color)
                    do { try manager.saveGroup(value); onSave(value.id) }
                    catch { self.error = TunnelCatalog.groupError(error) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 360)
        .onAppear { name = group?.name ?? ""; selectedParentID = group?.parentID ?? parentID }
    }
}
