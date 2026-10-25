import AppKit
import Observation
import SwiftUI
import macSCPCore

/// One launch task shared by every window and tunnel autostart. A refusal
/// remains refused; session actions never retry authentication implicitly.
@MainActor @Observable
final class CredentialStartup {
    static let shared = CredentialStartup()
    private var task: Task<Bool, Never>?
    private(set) var ready = false
    private(set) var failure: String?

    func prepare(retry: Bool = false) async -> Bool {
        if retry, failure != nil { task = nil; failure = nil }
        if let task { return await task.value }
        let task = Task { @MainActor in
            let result = await Task.detached {
                Result {
                    if retry { try SharedCredentialVault.shared.retryUnlockAtUserRequest() }
                    else { try SharedCredentialVault.shared.unlockAtLaunch() }
                }
            }.value
            switch result {
            case .success: ready = true; return true
            case .failure(let error): failure = error.localizedDescription; return false
            }
        }
        self.task = task
        return await task.value
    }
}

struct CredentialStartupView<Content: View>: View {
    @State private var startup = CredentialStartup.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if startup.ready {
                content()
            } else if let failure = startup.failure {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                        .help(L10n.string("vault.startup.title", "Credential vault locked"))
                    L10n.text("vault.startup.title", "Credential vault locked").font(.title2)
                    L10n.text("vault.startup.failure", "MacSCP could not open the credential vault. You can retry macOS authorization without restarting the application.")
                    Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L10n.string("vault.startup.retry", "Retry authorization")) {
                        Task { _ = await startup.prepare(retry: true) }
                    }
                    Button(L10n.string("vault.startup.quit", "Quit MacSCP")) { NSApp.terminate(nil) }
                }
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(minWidth: 500, minHeight: 300)
            } else {
                ProgressView(L10n.string("vault.startup.opening", "Opening credential vault…"))
                    .frame(minWidth: 500, minHeight: 300)
            }
        }
        .task { _ = await startup.prepare() }
    }
}
