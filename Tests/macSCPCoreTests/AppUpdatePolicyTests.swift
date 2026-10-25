import Foundation
import Testing
@testable import macSCPCore

@Suite("Application update distribution policy")
struct AppUpdatePolicyTests {
    @Test func storeMetadataAndCompileFlagDisableExternalUpdates() {
        #expect(!AppUpdatePolicy.allowsGitHub(distribution: "app-store"))
        #expect(AppUpdatePolicy.allowsGitHub(distribution: "direct")
            == !AppUpdatePolicy.isStoreBuild)
    }

    @Test(arguments: [nil, "direct", "app-store"] as [String?], [false, true])
    func storeAlwaysOwnsItsUpdates(distribution: String?, configured: Bool) {
        let presentation = AppUpdatePolicy.settingsPresentation(
            distribution: distribution, isPackagedApplication: true, isConfigured: configured)
        if distribution == "app-store" || AppUpdatePolicy.isStoreBuild {
            #expect(presentation == .appStore)
        } else {
            #expect(presentation == (configured ? .github : .unavailable))
        }
    }

    @Test(arguments: [false, true])
    func bareExecutablesNeverOfferAnInstallableUpdate(configured: Bool) {
        let presentation = AppUpdatePolicy.settingsPresentation(
            distribution: "direct", isPackagedApplication: false, isConfigured: configured)
        #expect(presentation == (AppUpdatePolicy.isStoreBuild ? .appStore : .localBuild))
    }

}
