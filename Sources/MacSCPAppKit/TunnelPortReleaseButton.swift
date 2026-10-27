import AppKit
import SwiftUI
import macSCPCore

/// Native sheets outlive the menu that initiated recovery. Keeping the prompt
/// on the menu item itself would dismiss its SwiftUI state when the menu closes.
struct TunnelPortReleaseButton: View {
    let profile: TunnelProfile
    let manager: TunnelManager
    let decider: HostKeyDecider

    var body: some View {
        if TunnelPortRelease.available(profile: profile, state: manager.state(of: profile.id)) {
            Button(L10n.string("tunnel.release.action", "Free port and restart…"), role: .destructive) {
                let window = NSApp.keyWindow
                Task { await recover(in: window) }
            }
        }
    }

    @MainActor
    private func recover(in window: NSWindow?) async {
        guard let window, window.attachedSheet == nil else { return }
        do {
            let endpoint = TunnelEndpoints.listener(profile)
            var owners = try await TunnelPortRelease.owners(of: endpoint)
            if owners.isEmpty { owners = try await TunnelPortRelease.owners(of: endpoint, privileged: true) }
            guard !owners.isEmpty else { throw TunnelPortRelease.Failure.unavailable }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("tunnel.release.title", "Free this port and restart the tunnel?")
            alert.informativeText = L10n.string("tunnel.release.warning", "The following processes will be terminated, forcibly if necessary. Their connections and unsaved work may be lost. macOS will request administrator authorization if required.")
                + "\n\n" + owners.map { "\($0.name) (PID \($0.pid))" }.joined(separator: "\n")
            alert.addButton(withTitle: L10n.string("common.cancel", "Cancel"))
            alert.addButton(withTitle: L10n.string("tunnel.release.confirm", "Terminate and restart"))
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return }
            guard manager.allProfiles.contains(profile),
                  TunnelPortRelease.available(profile: profile, state: manager.state(of: profile.id)) else { return }
            try await TunnelPortRelease.release(owners, endpoint: endpoint)
            // The profile may have been edited or removed while authorization
            // was open. Never restart the captured configuration in that case.
            guard manager.allProfiles.contains(profile),
                  TunnelPortRelease.available(profile: profile, state: manager.state(of: profile.id)) else { return }
            await manager.start(profile, decider: decider)
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.string("tunnel.release.error", "Could not free the port")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.string("common.ok", "OK"))
            await alert.beginSheetModal(for: window)
        }
    }
}
