import Foundation
import MacSCPTestSupport
import Testing

/// Source-level wiring only. SettingsStoreTests covers persistence; the
/// shared localization suites cover catalog parity and German address form.
@Suite("Settings controls wiring")
struct SettingsControlsWiringTests {
    @Test func startupOwnsTheOnlyLoginSwitchAndGeneralNoLongerMixesLaunchControls() throws {
        let root = SourceCorpus.packageRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let settings = try SourceCorpus.code(of: root.appendingPathComponent("SettingsView.swift"))
        let startup = try #require(SourceSpan.body(after: "private struct StartupSettingsSection: View", in: settings))
        let general = try #require(SourceSpan.body(after: "private struct GeneralSettingsSection: View", in: settings))
        let tunnels = try SourceCorpus.code(of: root.appendingPathComponent("TunnelAutostartSheet.swift"))
        #expect(startup.contains("loginItem.setEnabled"))
        #expect(startup.contains("TunnelAutostartSheet("))
        #expect(!general.contains("loginItem"))
        #expect(!general.contains("showTunnelAutostartSheet"))
        #expect(tunnels.contains("profileTable"))
        #expect(!tunnels.contains("loginItem.setEnabled"))
    }

    @Test(arguments: [
        ("AppearanceSettingsSection", "sidebarCompact", ["settings.appearance.sidebarCompact"]),
        ("TransfersSettingsTab", "transfersShowFullPaths", ["settings.transfers.showFullPaths"]),
        ("StartupSettingsSection", "restoresWindows", [
            "settings.general.restoreWindows", "settings.general.restoreWindows.footer",
        ]),
    ])
    func toggleUsesItsStoredSettingAndLocalizedLabels(
        section: String, property: String, keys: [String]
    ) throws {
        let file = SourceCorpus.packageRoot.appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")
        let declaration = "private struct \(section): View"
        let code = try #require(SourceSpan.body(after: declaration, in: SourceCorpus.code(of: file)))
        let literals = try #require(SourceSpan.body(after: declaration, in: SourceCorpus.commentFree(of: file)))
        #expect(code.contains("Toggle("))
        #expect(code.contains("store.\(property)"))
        for key in keys {
            #expect(literals.contains("\"\(key)\""))
        }
    }
}
