import macSCPCore

extension AppLanguage {
    /// Names stay in the catalogs, including the system-default option.
    var titleKey: String { "settings.general.language." + rawValue }
}
