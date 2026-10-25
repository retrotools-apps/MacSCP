import Foundation

/// Compile-time distribution takes precedence over mutable preferences.
public enum AppUpdatePolicy {
    public enum SettingsPresentation: Equatable, Sendable {
        case appStore, github, localBuild, unavailable
    }

    public static var isStoreBuild: Bool {
        #if MACSCP_APP_STORE
        true
        #else
        false
        #endif
    }

    public static func allowsGitHub(distribution: String?) -> Bool {
        !isStoreBuild && distribution != "app-store"
    }

    public static func settingsPresentation(distribution: String?, isPackagedApplication: Bool,
                                            isConfigured: Bool) -> SettingsPresentation {
        guard allowsGitHub(distribution: distribution) else { return .appStore }
        guard isPackagedApplication else { return .localBuild }
        return isConfigured ? .github : .unavailable
    }
}
