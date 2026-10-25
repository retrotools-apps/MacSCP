import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
import macSCPCore

@Suite("Sparkle direct distribution and Store exclusion")
@MainActor struct SparkleDistributionTests {
    private static let root = SourceCorpus.url(of: .sources).deletingLastPathComponent()

    @Test func unconfiguredTestProcessesCannotStartAnUpdaterOrNetworkCheck() {
        let updater = ApplicationUpdater()
        updater.start()
        updater.start()
        #expect(!updater.isConfigured)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.settingsPresentation == (AppUpdatePolicy.isStoreBuild ? .appStore : .localBuild))
        updater.checkForUpdates()
        if AppUpdatePolicy.isStoreBuild { #expect(updater.isStoreDistribution) }
    }

    @Test func nativeControllerIsCompileGuardedAndRuntimePolicyPrecedesStartup() throws {
        let source = try SourceCorpus.code(of: Self.root.appendingPathComponent("Sources/MacSCPAppKit/ApplicationUpdater.swift"))
        #expect(source.contains("#if MACSCP_SPARKLE && !MACSCP_APP_STORE"))
        #expect(source.contains("SPUStandardUpdaterController(startingUpdater: false"))
        let start = try #require(SourceSpan.body(after: "func start()", in: source))
        let policy = try #require(start.range(of: "guard !isStoreDistribution"))
        let creation = try #require(start.range(of: "SPUStandardUpdaterController("))
        #expect(policy.lowerBound < creation.lowerBound)
        #expect(source.contains("distribution: Bundle.main.object(forInfoDictionaryKey:"))
        #expect(!source.contains("appStoreReceiptURL"))
    }

    @Test(arguments: ["en", "de", "fr", "pl", "es", "ro", "it"])
    func catalogsCoverBothDistributionChannels(language: String) throws {
        let path = Self.root.appendingPathComponent("Sources/MacSCPAppKit/Resources/\(language).lproj/Localizable.strings").path
        let catalog = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        for key in ["settings.general.appStoreUpdates", "updates.check", "updates.automatic", "updates.footer", "updates.unconfigured",
                    "updates.title", "updates.download", "updates.localBuild"] {
            #expect(catalog[key]?.isEmpty == false)
        }
    }
}
