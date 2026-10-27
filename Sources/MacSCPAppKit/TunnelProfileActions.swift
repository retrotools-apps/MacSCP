import SwiftUI
import macSCPCore

extension TunnelPresentationState {
    static func isActive(_ state: TunnelState) -> Bool {
        if case .active = state { return true }
        return false
    }
}

/// Shared management actions for the workspace and its navigation rows.
struct TunnelProfileActions: ViewModifier {
    let profile: TunnelProfile
    let sessions: [StoredSession]
    let manager: TunnelManager
    let decider: HostKeyDecider
    @State private var editor: Editor?
    @State private var renaming = false
    @State private var name = ""
    @State private var deleting = false
    @State private var errorMessage: String?

    private enum Editor: String, Identifiable {
        case edit, duplicate
        var id: String { rawValue }
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            TunnelPortReleaseButton(profile: profile, manager: manager, decider: decider)
            Button(L10n.string("tunnel.action.start", "Start")) { Task { await manager.start(profile, decider: decider) } }
            Button(L10n.string("tunnel.action.stop", "Stop")) { Task { await manager.stop(profile) } }
            Divider()
            Button(L10n.string("tunnel.action.rename", "Rename…")) { name = profile.name; renaming = true }
            Button(L10n.string("tunnel.action.duplicate", "Duplicate…")) { editor = .duplicate }
            Button(L10n.string("tunnel.action.edit", "Edit")) { editor = .edit }
            Menu(L10n.string("sidebar.moveTo", "Move to")) {
                Button(L10n.string("tunnels.group.ungrouped", "Ungrouped")) { move(to: nil) }
                ForEach(manager.allGroups) { group in
                    Button(TunnelGroup.path(group, in: manager.allGroups)) { move(to: group.id) }
                }
            }
            Divider()
            Button(L10n.string("tunnel.action.delete", "Delete"), role: .destructive) { deleting = true }
        }
        .sheet(item: $editor) { mode in
            TunnelWorkspaceEditor(profile: profile, sessions: sessions.filter { $0.kind == .ssh }, manager: manager,
                                  onClose: { editor = nil }, isDuplicate: mode == .duplicate)
        }
        .alert(L10n.string("tunnel.action.rename", "Rename…"), isPresented: $renaming) {
            TextField(L10n.string("tunnel.field.name", "Name"), text: $name)
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
            Button(L10n.string("common.save", "Save")) {
                do { try manager.rename(profile, to: name) }
                catch { errorMessage = TunnelCatalog.groupError(error) }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(L10n.string("tunnels.delete.confirm", "Delete this tunnel? It will be stopped."), isPresented: $deleting) {
            Button(L10n.string("tunnel.action.delete", "Delete"), role: .destructive) {
                Task {
                    do { try await manager.remove(profile) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .alert(L10n.string("tunnels.error", "Tunnel could not be saved"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.string("common.ok", "OK")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func move(to groupID: UUID?) {
        do { try manager.move(profile, to: groupID) }
        catch { errorMessage = TunnelCatalog.groupError(error) }
    }
}
