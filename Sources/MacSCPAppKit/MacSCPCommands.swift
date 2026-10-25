import SwiftUI
import macSCPCore

/// The per-window menu bridge, published as a focused scene value.
///
/// `TabCommands` is created by each `ContentView` and handed to SwiftUI
/// with `.focusedSceneValue(\.tabCommands, …)`; `MacSCPCommands` below
/// reads it back with `@FocusedValue`. That is the whole reason this key
/// exists, and it replaced something worse (Detachable Tabs plan, Task 2
/// fix round 1): one app-wide `TabCommands` that every window overwrote,
/// with each closure carrying a `window?.isKeyWindow` guard to work out
/// afterwards whether it should act. Two windows made that unworkable —
/// the closures belonged to whichever window ran its setup last, and the
/// mirrored enabled-state values to whichever window changed last,
/// including a BACKGROUND one. A focused value asks the question SwiftUI
/// already knows the answer to.
///
/// `nil` means no MacSCP window is focused (the Settings window is in
/// front, or the app has no window at all): every entry below is disabled
/// or does nothing, which is exactly what the key-window guards were
/// trying to express.
private struct TabCommandsFocusedValueKey: FocusedValueKey {
    typealias Value = TabCommands
}

extension FocusedValues {
    var tabCommands: TabCommands? {
        get { self[TabCommandsFocusedValueKey.self] }
        set { self[TabCommandsFocusedValueKey.self] = newValue }
    }
}

/// Every menu this app adds to the menu bar.
///
/// A `Commands` type of its own rather than an inline `.commands { … }`
/// closure in `MacSCPApp.body`, because `@FocusedValue` is a dynamic
/// property: it belongs to a type SwiftUI can re-evaluate when the focused
/// window changes, and `App.body` is not that type.
///
/// `settingsStore` is app-global; window actions use the focused bridge.
struct MacSCPCommands: Commands {
    let settingsStore: SettingsStore
    var settingsBridge: SettingsWindowBridge? = nil
    var updater: ApplicationUpdater? = nil
    /// The focused window's bridge — see `TabCommandsFocusedValueKey`.
    @FocusedValue(\.tabCommands) private var tabCommands: TabCommands?
    @FocusedValue(\.fileInspectionActions) private var fileInspectionActions: FileInspectionActions?

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.string("menu.settings", "Settings…")) {
                if let show = tabCommands?.showSettings { show() }
                else {
                    settingsBridge?.settingsRequested = true
                    MainWindowPresentation.shared.show()
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button(L10n.string("about.title", "About MacSCP")) {
                AboutWindow.show()
            }
        }
        CommandGroup(after: .appInfo) {
            if let updater, updater.settingsPresentation == .github {
                Button(L10n.string("updates.check", "Check for Updates…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        // Replaces "New Window" (⌘N) with a tab in the focused window.
        // Detached windows remain available through the tab move command. "Close Tab"
        // (⌘W) lives in the same group; it shadows the system "Close"
        // command with the same shortcut (there is no dedicated
        // `CommandGroupPlacement` to replace it outright), routing through
        // `tabCommands.closeActiveTab` which falls back to closing the
        // window when the active tab is the last, unconnected one.
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("menu.newTab", "New Tab")) {
                tabCommands?.newTab?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(tabCommands == nil)
            // Disabled — not absent — when no MacSCP window is focused
            // (Detachable Tabs plan, Task 2 fix round 1). This item shadows
            // the system "Close" command with the same shortcut, and with
            // the focused value gone (the Settings window in front, say)
            // there is no window's tabs for it to act on; a disabled item
            // lets the shadowed system command take ⌘W instead of eating it.
            Button(L10n.string("menu.closeTab", "Close Tab")) {
                tabCommands?.closeActiveTab?()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabCommands == nil)
        }
        CommandGroup(after: .newItem) {
            Button(L10n.string("filetools.view", "View")) { fileInspectionActions?.view?() }
                .keyboardShortcut(KeyEquivalent("\u{F706}"), modifiers: [])
                .disabled(fileInspectionActions?.view == nil)
            Button(L10n.string("commander.edit", "Edit")) { fileInspectionActions?.edit?() }
                .keyboardShortcut(KeyEquivalent("\u{F707}"), modifiers: [])
                .disabled(fileInspectionActions?.edit == nil)
        }
        // Keep native window sizing and the open-window list; session tabs
        // have their own focused-window commands instead of NSWindow groups.
        CommandGroup(after: .windowArrangement) {
            Button(L10n.string("menu.previousTab", "Previous Tab")) {
                tabCommands?.selectAdjacentTab(by: -1)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled((tabCommands?.windowTabs.count ?? 0) < 2)
            Button(L10n.string("menu.nextTab", "Next Tab")) {
                tabCommands?.selectAdjacentTab(by: 1)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled((tabCommands?.windowTabs.count ?? 0) < 2)
            Button(L10n.string("window.moveTabToNewWindow", "Move Tab to New Window")) {
                tabCommands?.moveTabToNewWindow?()
            }
            .disabled(tabCommands?.canMoveTabToNewWindow != true)
            Toggle(L10n.string("window.keepOnTop", "Keep on Top"), isOn: Binding(
                get: { tabCommands?.keepOnTop ?? false },
                set: { _ in tabCommands?.toggleKeepOnTop?() }
            ))
            .disabled(tabCommands == nil)
            if let tabCommands, !tabCommands.windowTabs.isEmpty {
                Divider()
                ForEach(tabCommands.windowTabs) { item in
                    Toggle(item.title, isOn: Binding(
                        get: { item.isSelected },
                        set: { selected in if selected { tabCommands.selectTab?(item.index) } }
                    ))
                    .keyboardShortcut(item.shortcut)
                }
            }
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.string("menu.toggleHidden", "Show/Hide Hidden Files")) {
                settingsStore.showHiddenFiles.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button(L10n.string("menu.transfers.toggle", "Show/Hide Transfers")) {
                tabCommands?.toggleTransfers?()
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(tabCommands?.isActiveTabConnected != true)
        }
        // "Sessions" menu (M10a/T2, mockup section 4): bundles the
        // management sheets and the sidebar's existing export/import
        // actions in one menu-bar home. Same focused bridge as the other
        // `tabCommands` entries above — `ContentView.wireTabCommands()`
        // fills in its own window's closures, and only the focused
        // window's are reachable from here.
        CommandMenu(L10n.string("menu.sessions", "Sessions")) {
            Button(L10n.string("menu.knownHosts", "Known Hosts…")) {
                tabCommands?.showKnownHosts?()
            }
            .disabled(tabCommands == nil)
            .keyboardShortcut("k", modifiers: [.command, .shift])
            // "Server Certificates…": no shortcut — ⇧⌘K and ⇧⌘L are
            // taken, and "SSH Keys…"/"Hidden Imports…" set the precedent
            // that a management sheet does not need one.
            Button(L10n.string("menu.serverCertificates", "Server Certificates…")) {
                tabCommands?.showServerCertificates?()
            }
            .disabled(tabCommands == nil)
            Button(L10n.string("menu.logins", "Logins…")) {
                tabCommands?.showLogins?()
            }
            .disabled(tabCommands == nil)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            // "SSH Keys…" (M18/T5): opens the SSH-key management sheet —
            // same focused bridge as the other entries in this menu.
            Button(L10n.string("menu.sshKeys", "SSH Keys…")) {
                tabCommands?.showSSHKeys?()
            }
            .disabled(tabCommands == nil)
            // "Ad-hoc Connection Log…" (M31): the audit trail of every
            // connection that was never saved. It has no sidebar row to
            // open it from -- its session is a value, not a record.
            Button(L10n.string("menu.adHocAuditLog", "Ad-hoc Connection Log…")) {
                tabCommands?.showAdHocAuditLog?()
            }
            .disabled(tabCommands == nil)
            Divider()
            Button(L10n.string("transfer.export", "Export…")) {
                tabCommands?.exportAllSessions?()
            }
            .disabled(tabCommands == nil)
            Button(L10n.string("transfer.import", "Import…")) {
                tabCommands?.importSessions?()
            }
            .disabled(tabCommands == nil)
        }
        // A shell uses its own external terminal and the active SSH session.
        CommandMenu(L10n.string("menu.terminal", "Terminal")) {
            Button(L10n.string("menu.terminal.openExternal", "Open in External Terminal")) {
                tabCommands?.openExternalTerminal?()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(tabCommands?.isActiveTabConnected != true || tabCommands?.activeTabSupportsShell != true)
        }
        // No Help Book is shipped. Offer the existing in-app references
        // instead of a system Help item that has no content to open.
        CommandGroup(replacing: .help) {
            Button(L10n.string("menu.keyboardShortcuts", "Keyboard Shortcuts…")) {
                tabCommands?.showKeyboardShortcuts?()
            }
            .disabled(tabCommands == nil)
            Button(L10n.string("settings.tab.whatsNew", "What's New")) {
                tabCommands?.showWhatsNew?()
            }
            .disabled(tabCommands == nil)
        }
    }
}
