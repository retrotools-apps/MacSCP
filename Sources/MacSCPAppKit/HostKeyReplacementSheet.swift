import SwiftUI
import macSCPCore

struct HostKeyReplacementSheet: View {
    let change: HostKeyMismatchDetails
    let onReplace: () throws -> Bool
    let onClose: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill").font(.title).foregroundStyle(.red)
                    .accessibilityHidden(true)
                    .help(L10n.string("tofu.changed.warning", "The server identity has changed. The connection was stopped. Verify the new fingerprint independently before replacing the saved key."))
                L10n.text("connection.error.title", "Connection failed").font(.title2.weight(.semibold))
            }
            Text(change.host + (change.candidate.map { ":\($0.port)" } ?? ""))
                .font(.headline.monospaced()).textSelection(.enabled)
            L10n.text("tofu.changed.warning", "The server identity has changed. The connection was stopped. Verify the new fingerprint independently before replacing the saved key.")
                .fixedSize(horizontal: false, vertical: true)
            fingerprint(L10n.string("tofu.changed.saved", "Saved fingerprint"), change.expected)
            fingerprint(L10n.string("tofu.changed.presented", "Presented fingerprint"), change.presented)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    do {
                        if try onReplace() { onClose() }
                        else { errorMessage = L10n.string("tofu.replaceFailed", "The key could not be replaced. Run the connection again to review the current key.") }
                    } catch {
                        errorMessage = L10n.string("tofu.replaceFailed", "The key could not be replaced. Run the connection again to review the current key.")
                    }
                } label: {
                    L10n.text("tofu.replaceChangedKey", "Replace host key")
                }.buttonStyle(HostKeyReplacementButtonStyle())
            }
        }.padding(24).frame(width: 690, alignment: .leading)
    }

    private func fingerprint(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HostKeyReplacementPresentation: ViewModifier {
    let form: ConnectionViewModel
    let store: KnownHostsStore
    let auditStore: AuditLogStore

    func body(content: Content) -> some View {
        let pending = FormFailureAlertPlan.onAppear(state: form.state, unacknowledgedFailure: form.unacknowledgedFailure)
        content.sheet(isPresented: Binding(get: {
            pending != nil && form.lastHostKeyMismatch?.candidate != nil
        }, set: { shown in
            if !shown, let id = pending?.failureID { form.acknowledgeFailure(id) }
        })) {
            if let change = form.lastHostKeyMismatch, let pending {
                HostKeyReplacementSheet(change: change,
                    onReplace: { try form.replaceChangedHostKey(in: store, auditStore: auditStore) },
                    onClose: { if let id = pending.failureID { form.acknowledgeFailure(id) } })
            }
        }
    }
}

/// Keep the trust-changing action visibly red even in an inactive native window.
struct HostKeyReplacementButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color.red.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}
