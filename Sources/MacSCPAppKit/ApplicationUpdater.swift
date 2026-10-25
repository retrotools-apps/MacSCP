import Foundation
import Observation
import SwiftUI
import macSCPCore
#if MACSCP_SPARKLE && !MACSCP_APP_STORE
import Sparkle
#endif

/// Process-wide distribution service, independent of windows and sessions.
@Observable @MainActor
final class ApplicationUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var isConfigured = false
    var automaticChecks = false {
        didSet {
            #if MACSCP_SPARKLE && !MACSCP_APP_STORE
            if let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticChecks {
                updater.automaticallyChecksForUpdates = automaticChecks
            }
            #endif
        }
    }

    var isStoreDistribution: Bool {
        !AppUpdatePolicy.allowsGitHub(
            distribution: Bundle.main.object(forInfoDictionaryKey: "MacSCPDistribution") as? String)
    }

    var settingsPresentation: AppUpdatePolicy.SettingsPresentation {
        AppUpdatePolicy.settingsPresentation(
            distribution: Bundle.main.object(forInfoDictionaryKey: "MacSCPDistribution") as? String,
            isPackagedApplication: Bundle.main.bundleURL.pathExtension == "app",
            isConfigured: isConfigured)
    }

    #if MACSCP_SPARKLE && !MACSCP_APP_STORE
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticObservation: NSKeyValueObservation?
    #endif
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        guard !isStoreDistribution else { return }
        #if MACSCP_SPARKLE && !MACSCP_APP_STORE
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            isConfigured = true
            automaticChecks = controller.updater.automaticallyChecksForUpdates
            checkObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
            }
            automaticObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor [weak self] in self?.automaticChecks = value }
            }
        } catch {
            self.controller = nil
        }
        #endif
    }

    func checkForUpdates() {
        guard !isStoreDistribution, isConfigured, canCheckForUpdates else { return }
        #if MACSCP_SPARKLE && !MACSCP_APP_STORE
        controller?.checkForUpdates(nil)
        #endif
    }
}

private struct ApplicationUpdaterKey: SwiftUI.EnvironmentKey {
    static let defaultValue: ApplicationUpdater? = nil
}

extension EnvironmentValues {
    var applicationUpdater: ApplicationUpdater? {
        get { self[ApplicationUpdaterKey.self] }
        set { self[ApplicationUpdaterKey.self] = newValue }
    }
}
