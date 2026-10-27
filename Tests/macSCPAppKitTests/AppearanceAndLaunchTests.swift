import Foundation
import Testing
@testable import macSCPCore
@testable import MacSCPAppKit

@MainActor
struct AppearanceAndLaunchTests {
    @Test func contrastDefaultsToOriginalAndPersistsAcrossReload() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(directory: directory)
        #expect(!settings.highContrast)
        settings.highContrast = true
        #expect(SettingsStore(directory: directory).highContrast)
        settings.highContrast = false
        #expect(!SettingsStore(directory: directory).highContrast)
    }

    @Test func customAppearanceColorsRoundTripAndOldAppearancesStillDecode() throws {
        let color = GroupColor(rgb: 0x007AFF)
        let appearance = SessionAppearance(icon: .server, customColor: color)
        let tunnel = TunnelAppearance(icon: .web, customColor: color)
        let encoder = JSONEncoder()
        #expect(try JSONDecoder().decode(SessionAppearance.self, from: encoder.encode(appearance)) == appearance)
        #expect(try JSONDecoder().decode(TunnelAppearance.self, from: encoder.encode(tunnel)) == tunnel)
        let old = Data(#"{"icon":"server","tint":"blue"}"#.utf8)
        #expect(try JSONDecoder().decode(SessionAppearance.self, from: old).customColor == nil)
        #expect(try JSONDecoder().decode(TunnelAppearance.self, from: old).customColor == nil)
    }

    @Test func activeFilterIncludesEstablishedAndDegradedTunnelsOnly() {
        #expect(TunnelPresentationState.isActive(.active(connections: 0)))
        #expect(TunnelPresentationState.isActive(.active(connections: 2, failedConnections: 1, lastFailure: .connectionFailed)))
        #expect(!TunnelPresentationState.isActive(.stopped))
        #expect(!TunnelPresentationState.isActive(.connecting))
        #expect(!TunnelPresentationState.isActive(.failed(.connectionFailed)))
        #expect(!TunnelPresentationState.isActive(.needsConfirmation))
    }

    @Test func ordinaryDocumentLaunchReusesTheAppWithoutOverridingArguments() {
        let configuration = ExternalTerminalLauncher.launchConfiguration()
        #expect(configuration.arguments.isEmpty)
        #expect(!configuration.createsNewApplicationInstance)
        #expect(!configuration.addsToRecentItems)
    }

    @Test func onlyColdTerminalLaunchesUseTheSystemFreshLaunchFlag() {
        let application = URL(fileURLWithPath: "/Applications/Terminal Test.app")
        let script = URL(fileURLWithPath: "/tmp/test path ' quoted.command")
        #expect(ExternalTerminalLauncher.freshLaunchArguments(target: .terminalApp,
            application: application, script: script, isRunning: false)
            == ["-F", "-a", application.path, "--", script.path])
        for target in [TerminalTarget.terminalApp, .iTerm, .custom] {
            #expect(ExternalTerminalLauncher.freshLaunchArguments(target: target,
                application: application, script: script, isRunning: true) == nil)
        }
        for target in [TerminalTarget.iTerm, .custom] {
            #expect(ExternalTerminalLauncher.freshLaunchArguments(target: target,
                application: application, script: script, isRunning: false) == nil)
        }
    }
}
