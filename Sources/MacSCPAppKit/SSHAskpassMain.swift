import AppKit
import Darwin
import Foundation
import macSCPCore

extension AppMain {
    /// OpenSSH's helper mode never starts the application or its auto-start
    /// tunnels. Only a broker-authorized request may display a fallback prompt.
    @MainActor
    public static func runAskpassIfRequested(_ arguments: [String]) {
        guard arguments.dropFirst().first == "--internal-ssh-askpass" else { return }
        guard arguments.count == 5 else { Darwin.exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let reply = try await SSHAskpassSession.request(
                    socketPath: arguments[2], token: arguments[3], prompt: arguments[4])
                guard reply.authorized else { Darwin.exit(1) }
                guard let answer = reply.answer ?? manualAnswer(to: arguments[4]) else { Darwin.exit(1) }
                FileHandle.standardOutput.write(Data((answer + "\n").utf8))
                Darwin.exit(0)
            } catch { Darwin.exit(1) }
        }
        // dispatchMain can release Darwin's original main thread, allowing
        // MainActor work to run elsewhere. NSAlert requires the actual main
        // thread, so this helper must service it with AppKit's event loop.
        app.run()
    }

    @MainActor
    private static func manualAnswer(to prompt: String) -> String? {
        let app = NSApplication.shared
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.informativeText = prompt
        if prompt.contains("Are you sure you want to continue connecting") {
            alert.alertStyle = .warning
            alert.messageText = L10n.string("externalTerminal.askpass.hostKey", "Verify SSH host key")
            alert.addButton(withTitle: L10n.string("externalTerminal.askpass.accept", "Accept"))
            alert.addButton(withTitle: L10n.string("common.cancel", "Cancel"))
            return alert.runModal() == .alertFirstButtonReturn ? "yes" : nil
        }
        alert.messageText = L10n.string("externalTerminal.askpass.title", "SSH authentication")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.string("externalTerminal.askpass.continue", "Continue"))
        alert.addButton(withTitle: L10n.string("common.cancel", "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
