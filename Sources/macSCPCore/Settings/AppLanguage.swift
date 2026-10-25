/// The app's UI language, chosen in Settings independent of the system
/// language. `.system` follows the OS; explicit choices select a resource
/// catalog through LocalizationContext, configured at application launch.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case en
    case de
    case fr
    case pl
    case es
    case ro
    case it

    /// The catalog code, or `nil` to follow the system language.
    public var localeCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        case .es: return "es"
        case .ro: return "ro"
        case .it: return "it"
        }
    }
}
