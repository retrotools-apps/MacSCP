import SwiftUI
import macSCPCore

private enum CredentialSettingsAction: Sendable { case enable, disable }

/// Migration is explicit and runs off the main actor. An unsigned development
/// executable cannot offer a biometric toggle that merely pretends to protect data.
struct CredentialSettingsSection: View {
    @State private var enabled = CredentialProtection.isEnabled
    @State private var busy = false
    @State private var confirmation = false
    @State private var message: String?
    @State private var failed = false

    private func perform(_ action: CredentialSettingsAction) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    switch action {
                    case .enable: return try CredentialProtection.enable()
                    case .disable: return try CredentialProtection.disable()
                    }
                }
            }.value
            enabled = CredentialProtection.isEnabled
            busy = false
            switch result {
            case .success(let count):
                failed = false
                message = String(format: L10n.string("credentials.settings.done", "%lld credential entries updated."), count)
            case .failure(let error):
                failed = true
                message = L10n.string("credentials.settings.failed",
                    "The operation did not finish. Already migrated entries remain usable; remaining originals were not removed. Retry to finish.")
                    + "\n" + error.localizedDescription
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Label(enabled ? L10n.string("credentials.settings.protected", "Touch ID protection enabled")
                              : L10n.string("credentials.settings.standard", "Standard macOS Keychain"),
                      systemImage: enabled ? "touchid" : "lock")
                    .help(L10n.string("credentials.settings.authentication", "Credential authentication"))
                Button(enabled ? L10n.string("credentials.settings.disable", "Return to standard Keychain…")
                               : L10n.string("credentials.settings.enable", "Protect saved credentials with Touch ID…")) {
                    confirmation = true
                }
                .disabled(busy || !CredentialProtection.hasSignedKeychainIdentity
                          || (!enabled && !CredentialProtection.hasEnrolledBiometrics))
                if !CredentialProtection.hasSignedKeychainIdentity {
                    Text(L10n.string("credentials.settings.signing",
                        "Touch ID requires a signed application with Keychain entitlements. It is unavailable in an ad-hoc or swift run build. No credentials have been migrated automatically."))
                        .foregroundStyle(.secondary)
                } else if !CredentialProtection.hasEnrolledBiometrics {
                    Text(L10n.string("credentials.settings.enroll", "Set up Touch ID in macOS System Settings first."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.string("credentials.settings.authentication", "Credential authentication"))
            } footer: {
                Text(L10n.string("credentials.settings.details",
                    "Protection is enforced by macOS when reading the secret, not by an app-only lock screen. macOS can offer your login password as a fallback. Active SSH connections are not re-authenticated."))
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).foregroundStyle(failed ? Color.red : Color.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .confirmationDialog(L10n.string("credentials.settings.confirmTitle", "Change credential protection?"),
                            isPresented: $confirmation) {
            Button(L10n.string("credentials.settings.confirm", "Migrate credentials"), role: .destructive) {
                perform(enabled ? .disable : .enable)
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("credentials.settings.confirmDetails",
                "The common vault is copied, authenticated and verified before its previous copy is removed. Returning to standard storage removes the Touch ID requirement. Never change signing identity without migrating first."))
        }
    }
}
