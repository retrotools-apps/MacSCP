import SwiftUI
import macSCPCore

/// Window-local navigation only. The underlying workspace remains mounted.
struct SettingsWorkspaceView: View {
    let store: SettingsStore
    let launchLanguage: AppLanguage
    let settingsBridge: SettingsWindowBridge
    @Binding var selection: SettingsSection?
    let onClose: () -> Void

    var body: some View {
        SettingsView(store: store, 
            launchLanguage: launchLanguage, settingsBridge: settingsBridge, selection: $selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
    }
}
