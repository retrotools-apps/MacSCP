import Foundation
import Synchronization

/// Resolves resource catalogs explicitly, independently of the main bundle's
/// cached language negotiation. This also supports bare SwiftPM executables.
public final class LocalizationContext: Sendable {
    public static let shared = LocalizationContext()

    private let language: Mutex<AppLanguage>
    private let systemLanguages: [String]

    public init(language: AppLanguage = .system, systemLanguages: [String]? = nil) {
        self.language = Mutex(language)
        // Read the OS preference, not an AppleLanguages override left in this
        // application's defaults by an older build of the language switcher.
        self.systemLanguages = systemLanguages
            ?? (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])
            ?? Locale.preferredLanguages
    }

    /// The app sets this once from persisted settings at launch. Views keep
    /// the launch language until the user explicitly relaunches the app.
    public func configure(language: AppLanguage) {
        self.language.withLock { $0 = language }
    }

    public func localizedBundle(in resources: Bundle) -> Bundle {
        let selected = language.withLock { $0 }
        let preferences = selected.localeCode.map { [$0] } ?? systemLanguages
        let language = Bundle.preferredLocalizations(
            from: resources.localizations, forPreferences: preferences).first ?? "en"
        guard let path = resources.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }
}
