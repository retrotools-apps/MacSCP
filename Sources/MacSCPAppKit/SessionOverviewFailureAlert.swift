import SwiftUI
import macSCPCore

/// Keep stored-session refusals over the overview. Editing is explicit.
struct SessionOverviewFailureAlert: ViewModifier {
    let form: ConnectionViewModel
    let onEdit: () -> Void

    func body(content: Content) -> some View {
        let pending = FormFailureAlertPlan.onAppear(state: form.state, unacknowledgedFailure: form.unacknowledgedFailure)
        content.alert(L10n.string("connection.error.title", "Connection failed"),
            isPresented: Binding(get: { pending != nil }, set: { shown in
                if !shown, let id = pending?.failureID { form.acknowledgeFailure(id) }
            }), presenting: pending) { _ in
                Button(L10n.string("sidebar.edit", "Edit…"), action: onEdit)
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }
}
