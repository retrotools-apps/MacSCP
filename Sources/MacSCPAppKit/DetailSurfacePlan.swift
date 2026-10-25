import Foundation
import macSCPCore

/// What an unconnected tab's detail pane shows (jump-and-groups plan, Task
/// 1): one of the three attempt surfaces, the read-only session overview,
/// or the connection form.
///
/// `ConnectionAttemptSurface`'s three attempt cases, plus the overview.
/// The overview carries the session it describes, so the view that renders
/// it has nothing left to look up — and so nothing left to decide.
enum DetailSurface: Equatable {
    /// "Connecting…" with a Cancel control (`ConnectingAttemptView`).
    case connecting
    /// A connection that existed and dropped (`LostConnectionView`).
    case lost
    /// An attempt that failed on the wire (`ConnectFailureView`).
    case failed
    /// The connection form — also the only place TOFU's trust card is
    /// rendered, and where unsaved/edit-draft failure alerts are shown.
    case form
    /// An explicitly dismissed empty draft, with a New connection action.
    case dismissedForm
    /// The stored session the sidebar (or a restored tab) points at,
    /// described read-only (`SessionOverviewView`).
    case overview(StoredSession)
    /// The selected folder's saved sessions, never a connected workspace.
    case groupOverview(StoredGroup)
}

/// Attempt surfaces take precedence. Pending SSH trust cards always remain
/// visible on the form. A saved-session refusal is instead presented by
/// SessionOverviewFailureAlert over its overview, including the update before
/// liveness catches up. Explicit edit drafts and unsaved forms stay visible.
enum DetailSurfacePlan {
    /// The overview owns saved-session failure alerts. Only pending trust
    /// cards, explicit edit drafts and unsaved forms require the form itself.
    /// An unacknowledged failure also beats lagging connecting liveness, but
    /// never replaces the lost-connection flow.
    static func surface(
        liveness: ConnectionLiveness?, hostKeyPromptPending: Bool, connectAttemptFailed: Bool,
        describesLostConnection: Bool, unacknowledgedFailure: Bool,
        formMode: ConnectionViewModel.FormMode, overviewSession: StoredSession?,
        newFormDismissed: Bool = false, overviewGroup: StoredGroup? = nil
    ) -> DetailSurface {
        switch ConnectionSurfacePlan.surface(
            for: liveness, hostKeyPromptPending: hostKeyPromptPending,
            connectAttemptFailed: connectAttemptFailed)
        {
        case .connecting:
            if unacknowledgedFailure && !describesLostConnection {
                if let overviewSession, formMode == .new, !hostKeyPromptPending { return .overview(overviewSession) }
                return .form
            }
            return .connecting
        case .lost: return .lost
        case .failed: return .failed
        case .form:
            if let overviewGroup, formMode == .new, !hostKeyPromptPending, !unacknowledgedFailure {
                return .groupOverview(overviewGroup)
            }
            if newFormDismissed, formMode == .new, overviewSession == nil,
               !hostKeyPromptPending, !unacknowledgedFailure {
                return .dismissedForm
            }
            guard let overviewSession, formMode == .new, !hostKeyPromptPending
            else { return .form }
            return .overview(overviewSession)
        }
    }
}
