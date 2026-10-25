/// Where an external SSH session opens: a well-known application resolved
/// by bundle identifier, or a custom application at
/// a stored path. Combined with `SettingsStore.customTerminalAppPath` at the
/// App layer (`ExternalTerminalLauncher`) to resolve an actual application
/// URL.
public enum TerminalTarget: String, Codable, CaseIterable, Sendable {
    case terminalApp
    case iTerm
    case custom
}
