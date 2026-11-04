import SwiftUI
import macSCPCore

struct GroupDefaultsSheet: View {
    let group: StoredGroup
    let viewModel: SessionListViewModel
    let onClose: () -> Void

    @State private var loginSetID: UUID?
    @State private var relaySessionID: UUID?

    init(group: StoredGroup, viewModel: SessionListViewModel, onClose: @escaping () -> Void) {
        self.group = group
        self.viewModel = viewModel
        self.onClose = onClose
        _loginSetID = State(initialValue: group.loginSetID)
        _relaySessionID = State(initialValue: group.sshRelaySessionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(format: L10n.string(
                "group.settings.title %@", "Settings for “%@”"), group.name))
                .font(.title2.weight(.semibold))
            Text(L10n.string(
                "group.settings.precedence",
                "A connection’s own setting takes priority, then the nearest group setting, then its parent groups."))
                .foregroundStyle(.secondary)

            GroupBox(L10n.string("group.settings.credentials", "Default credentials")) {
                Picker(L10n.string("group.settings.loginSet", "Login set"), selection: $loginSetID) {
                    Text(L10n.string("group.settings.none", "None (inherit from parent)"))
                        .tag(UUID?.none)
                    ForEach(viewModel.loginSets) { set in
                        Text("\(set.name) · \(set.kind.rawValue.uppercased())")
                            .tag(Optional(set.id))
                    }
                }
                .pickerStyle(.menu)
                .padding(8)
            }

            GroupBox(L10n.string("group.settings.relay", "SSH relay (ProxyJump)")) {
                Picker(
                    L10n.string("group.settings.relayConnection", "Saved SSH connection"),
                    selection: $relaySessionID
                ) {
                    Text(L10n.string("group.settings.none", "None (inherit from parent)"))
                        .tag(UUID?.none)
                    ForEach(viewModel.sessions.filter { $0.kind == .ssh }) { session in
                        Text(session.name).tag(Optional(session.id))
                    }
                }
                .pickerStyle(.menu)
                .padding(8)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel, action: onClose)
                Button(L10n.string("common.save", "Save")) {
                    if viewModel.setGroupDefaults(
                        group, loginSetID: loginSetID,
                        sshRelaySessionID: relaySessionID) {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
