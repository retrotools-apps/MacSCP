import Foundation
import Observation

/// Minimal JSON value type for `SettingsStore`'s raw backing.
///
/// Used exclusively internally to achieve forward compatibility: keys this
/// app version doesn't know about are kept here as `JSONValue` and written
/// back unchanged when saving.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Central app settings. JSON in `<directory>/settings.json` —
/// FORWARD-COMPATIBLE: unknown keys are preserved when saving (round-tripped
/// through a raw `[String: JSONValue]` backing, with typed accessors on top).
/// Not a secret store.
@Observable
@MainActor
public final class SettingsStore {
    public var highContrast: Bool {
        get { boolValue(for: "highContrast", default: false) }
        set { setBool(newValue, for: "highContrast") }
    }

    private enum Keys {
        static let maxConcurrentTransfers = "maxConcurrentTransfers"
        static let uploadLimitKBs = "uploadLimitKBs"
        static let downloadLimitKBs = "downloadLimitKBs"
        static let defaultEditorPath = "defaultEditorPath"
        static let fileAssociations = "fileAssociations"
        static let showHiddenFiles = "showHiddenFiles"
        static let autoRefreshEnabled = "autoRefreshEnabled"
        static let autoRefreshIntervalSeconds = "autoRefreshIntervalSeconds"
        static let notificationsEnabled = "notificationsEnabled"
        static let terminalTarget = "terminalTarget"
        static let customTerminalAppPath = "customTerminalAppPath"
        static let externalTerminalPasswordHintShown = "externalTerminalPasswordHintShown"
        static let visibleColumns = "visibleColumns"
        static let menuBarEnabled = "menuBarEnabled"
        static let appLanguage = "appLanguage"
        static let presignedDefaultExpiry = "presignedDefaultExpiry"
        static let reconnectBehaviour = "reconnectBehaviour"
        static let keepAliveEnabled = "keepAliveEnabled"
        static let keepAliveIntervalSeconds = "keepAliveIntervalSeconds"
        static let connectTimeoutSeconds = "connectTimeoutSeconds"
        static let throughputPayloadMiB = "throughputPayloadMiB"
        static let sidebarWidth = "sidebarWidth"
        static let sidebarCompact = "sidebarCompact"
        static let groupColorsEnabled = "groupColorsEnabled"
        static let checksumAlgorithm = "checksumAlgorithm"
        static let transfersShowFullPaths = "transfersShowFullPaths"
        static let lastSeenVersion = "lastSeenVersion"
        static let diagnosticLogLevel = "diagnosticLogLevel"
        static let diagnosticSystemInformation = "diagnosticSystemInformation"
        static let diagnosticPublicAddresses = "diagnosticPublicAddresses"
        static let restoresWindows = "restoresWindows"
        static let mainWindowBrowserSize = "mainWindowBrowserSize"
    }

    private enum Defaults {
        static let maxConcurrentTransfers = 3
        static let uploadLimitKBs = 0
        static let downloadLimitKBs = 0
        static let showHiddenFiles = false
        static let autoRefreshEnabled = true
        static let autoRefreshIntervalSeconds = 5
        static let notificationsEnabled = true
        static let menuBarEnabled = true
        static let presignedDefaultExpiry = PresignedExpiry.oneHour
        static let reconnectBehaviour = ReconnectBehaviour.offerOnly
        static let keepAliveEnabled = true
        static let keepAliveIntervalSeconds = 60
        static let connectTimeoutSeconds = 10
        /// Read off the diagnosis's own settings type, like
        /// `checksumAlgorithm` below: the range and the default are the
        /// throughput test's, and a second copy here could drift from the
        /// one the CLI's `--payload-mib` is checked against.
        static let throughputPayloadMiB = DiagnosticThroughputSettings.defaultPayloadMiB
        /// Cloudflare, read off the diagnosis's own settings type for
        /// `throughputPayloadMiB`'s reason — the maintainer's answer of
        /// 2026-09-19 is recorded there, and a second copy here could
        /// drift from the one `macscp-cli diagnose --speed-service`
        /// defaults to.
        static let sidebarWidth = 180
        static let sidebarCompact = false
        static let groupColorsEnabled = true
        /// Read off the algorithm itself rather than spelled again here:
        /// which procedure is preferred is a property of the procedures,
        /// and a second copy of it is a second thing to keep in step.
        static let checksumAlgorithm = ChecksumAlgorithm.preferred
        static let transfersShowFullPaths = false
        static let diagnosticLogLevel = DiagnosticLogLevel.off
        static let restoresWindows = false
    }

    /// Identical to `SessionStore.defaultDirectory` — both stores share the
    /// app support directory, but each has its own file.
    public static let defaultDirectory: URL = SessionStore.defaultDirectory

    private let directory: URL

    /// Raw backing, loaded directly from the file. Unknown keys are left
    /// untouched here and get written back out on every `persist()`.
    private var raw: [String: JSONValue]

    private var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    /// Loads immediately from `<directory>/settings.json`. If the file is
    /// missing or unreadable/not valid JSON, the defaults apply (no crash) —
    /// the file is only replaced on the next save.
    public init(directory: URL) {
        self.directory = directory
        self.raw = Self.loadRaw(from: directory)
    }

    private static func loadRaw(from directory: URL) -> [String: JSONValue] {
        let fileURL = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return [:]
        }
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    // MARK: - Typed accessors

    /// Maximum concurrent transfers (clamped to 1...8, default 3).
    public var maxConcurrentTransfers: Int {
        get { clamp(intValue(for: Keys.maxConcurrentTransfers, default: Defaults.maxConcurrentTransfers), 1, 8) }
        set { setInt(clamp(newValue, 1, 8), for: Keys.maxConcurrentTransfers) }
    }

    /// Upload bandwidth limit in KB/s; 0 = unlimited (default 0). Clamped >= 0.
    public var uploadLimitKBs: Int {
        get { clamp(intValue(for: Keys.uploadLimitKBs, default: Defaults.uploadLimitKBs), 0, .max) }
        set { setInt(clamp(newValue, 0, .max), for: Keys.uploadLimitKBs) }
    }

    /// Download bandwidth limit in KB/s; 0 = unlimited (default 0). Clamped >= 0.
    public var downloadLimitKBs: Int {
        get { clamp(intValue(for: Keys.downloadLimitKBs, default: Defaults.downloadLimitKBs), 0, .max) }
        set { setInt(clamp(newValue, 0, .max), for: Keys.downloadLimitKBs) }
    }

    /// Show every transfer row's full source and destination paths on a
    /// second line, without hovering or opening the row's context menu
    /// (maintainer request 2026-09-03, after trying the dev build). Default
    /// OFF — the row stays as compact as it always has been until asked for.
    public var transfersShowFullPaths: Bool {
        get { boolValue(for: Keys.transfersShowFullPaths, default: Defaults.transfersShowFullPaths) }
        set { setBool(newValue, for: Keys.transfersShowFullPaths) }
    }

    /// Absolute path to the .app bundle used as the default editor for remote
    /// files; nil/empty = use the macOS system association. Persisted.
    public var defaultEditorPath: String? {
        get {
            guard case .string(let value)? = raw[Keys.defaultEditorPath], !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty {
                raw[Keys.defaultEditorPath] = .string(newValue)
            } else {
                raw[Keys.defaultEditorPath] = nil
            }
            persist()
        }
    }

    /// Per-extension overrides: normalized extension (lowercase, no leading
    /// dot, trimmed) -> absolute .app path. Assigning an empty app path for an
    /// extension removes that rule instead of storing it. Empty/whitespace-only
    /// extensions are ignored on write.
    public var fileAssociations: [String: String] {
        get {
            guard case .object(let entries)? = raw[Keys.fileAssociations] else { return [:] }
            var result: [String: String] = [:]
            for (rawExtension, value) in entries {
                guard case .string(let appPath) = value else { continue }
                let normalizedExtension = Self.normalizeExtension(rawExtension)
                guard !normalizedExtension.isEmpty else { continue }
                result[normalizedExtension] = appPath
            }
            return result
        }
        set {
            var normalized: [String: JSONValue] = [:]
            for (rawExtension, appPath) in newValue {
                let normalizedExtension = Self.normalizeExtension(rawExtension)
                guard !normalizedExtension.isEmpty, !appPath.isEmpty else { continue }
                normalized[normalizedExtension] = .string(appPath)
            }
            raw[Keys.fileAssociations] = normalized.isEmpty ? nil : .object(normalized)
            persist()
        }
    }

    /// Show dotfiles in both panes (M7a). Default OFF — the Finder-like
    /// default; ⌘⇧. and the General settings tab toggle it.
    public var showHiddenFiles: Bool {
        get { boolValue(for: Keys.showHiddenFiles, default: Defaults.showHiddenFiles) }
        set { setBool(newValue, for: Keys.showHiddenFiles) }
    }

    /// Auto-refresh of the active tab's remote pane (M9c). Default ON.
    public var autoRefreshEnabled: Bool {
        get { boolValue(for: Keys.autoRefreshEnabled, default: Defaults.autoRefreshEnabled) }
        set { setBool(newValue, for: Keys.autoRefreshEnabled) }
    }

    /// Interval in seconds, clamped to 2...300 on BOTH ends so a hand-edited
    /// settings.json cannot produce SFTP spam or a dead timer.
    public var autoRefreshIntervalSeconds: Int {
        get {
            clamp(
                intValue(for: Keys.autoRefreshIntervalSeconds, default: Defaults.autoRefreshIntervalSeconds),
                2, 300)
        }
        set { setInt(clamp(newValue, 2, 300), for: Keys.autoRefreshIntervalSeconds) }
    }

    /// Whether MacSCP posts a macOS notification when a connection is lost,
    /// a transfer fails or a port forwarding fails (next build of
    /// 2026-09-17, Task 7). One switch for all three. Default ON: the
    /// maintainer asked for the notifications (2026-09-16), and macOS still
    /// asks the user for permission at the first one.
    ///
    /// Core stores the flag and knows nothing else about it: when a
    /// notification is posted, and what it says, are App-layer decisions
    /// (`ErrorNotificationPlan`).
    public var notificationsEnabled: Bool {
        get { boolValue(for: Keys.notificationsEnabled, default: Defaults.notificationsEnabled) }
        set { setBool(newValue, for: Keys.notificationsEnabled) }
    }

    /// Whether the app shows its menu-bar status item (M11n). Default on.
    public var menuBarEnabled: Bool {
        get { boolValue(for: Keys.menuBarEnabled, default: Defaults.menuBarEnabled) }
        set { setBool(newValue, for: Keys.menuBarEnabled) }
    }

    /// Whether a launch reopens the windows the last quit left behind
    /// (Detachable Tabs plan, Task 5). Default OFF.
    ///
    /// Off is the default because restoring is not free of consequence: it
    /// puts hosts on screen that nobody asked to see this morning, and a
    /// settings.json predating this key must open exactly the one window
    /// it always has. What restoration brings back is deliberately less
    /// than what was there — windows, their tabs and each tab's stored
    /// session, DISCONNECTED. Nothing connects until the user does, which
    /// is the promise the settings footer makes and a source guard on the
    /// launch path keeps.
    ///
    /// Core stores the flag and knows nothing else about it: which file
    /// the seeds live in, what a seed contains and when it is read are all
    /// App-layer facts (`WindowRestorationStore`, `WindowRestorationPlan`),
    /// because nothing in Core knows about windows.
    public var restoresWindows: Bool {
        get { boolValue(for: Keys.restoresWindows, default: Defaults.restoresWindows) }
        set { setBool(newValue, for: Keys.restoresWindows) }
    }

    /// The size the main window was last used at while it showed a file
    /// browser, in points — `nil` until it has been (key
    /// `mainWindowBrowserSize`, stored as `{"width": w, "height": h}`).
    ///
    /// A connect grows the main window to this size rather than to the
    /// smallest browser size, so a window that shrank to the connection form
    /// on a disconnect — or came back at the form size after a relaunch —
    /// opens its next session at the size it was used at. Geometry, not a
    /// secret, and not a window: when it is written and what it grows are
    /// App-layer decisions (`MainWindowSizePlan`), because nothing in Core
    /// knows about windows.
    ///
    /// Anything on disk that is not two positive, finite numbers — a hand
    /// edit, a future format — reads as `nil`: no remembered size, rather
    /// than a window with no width. Setting `nil` removes the key.
    public var mainWindowBrowserSize: CGSize? {
        get {
            guard case .object(let size)? = raw[Keys.mainWindowBrowserSize],
                  case .number(let width)? = size["width"],
                  case .number(let height)? = size["height"],
                  width.isFinite, height.isFinite, width > 0, height > 0
            else { return nil }
            return CGSize(width: width, height: height)
        }
        set {
            if let newValue {
                raw[Keys.mainWindowBrowserSize] = .object([
                    "width": .number(Double(newValue.width)),
                    "height": .number(Double(newValue.height)),
                ])
            } else {
                raw[Keys.mainWindowBrowserSize] = nil
            }
            persist()
        }
    }

    /// Tighter connection and tunnel rows with auxiliary metadata hidden.
    /// Disabled by default; the saved profiles and their actions are unchanged.
    public var sidebarCompact: Bool {
        get { boolValue(for: Keys.sidebarCompact, default: Defaults.sidebarCompact) }
        set { setBool(newValue, for: Keys.sidebarCompact) }
    }

    public var diagnosticSystemInformation: Bool {
        get { boolValue(for: Keys.diagnosticSystemInformation, default: true) }
        set { setBool(newValue, for: Keys.diagnosticSystemInformation) }
    }

    public var diagnosticPublicAddresses: Bool {
        get { boolValue(for: Keys.diagnosticPublicAddresses, default: false) }
        set { setBool(newValue, for: Keys.diagnosticPublicAddresses) }
    }

    /// Disabling color keeps group regions visible in alternating neutral tones.
    public var groupColorsEnabled: Bool {
        get { boolValue(for: Keys.groupColorsEnabled, default: Defaults.groupColorsEnabled) }
        set { setBool(newValue, for: Keys.groupColorsEnabled) }
    }

    public var terminalTarget: TerminalTarget {
        get {
            guard case .string(let value)? = raw[Keys.terminalTarget] else {
                return .terminalApp
            }
            return TerminalTarget(rawValue: value) ?? .terminalApp
        }
        set {
            raw[Keys.terminalTarget] = .string(newValue.rawValue)
            persist()
        }
    }

    public var customTerminalAppPath: String? {
        get { stringValue(for: Keys.customTerminalAppPath) }
        set { setString(newValue, for: Keys.customTerminalAppPath) }
    }

    public var lastSeenVersion: String? {
        get { stringValue(for: Keys.lastSeenVersion) }
        set { setString(newValue, for: Keys.lastSeenVersion) }
    }

    /// Diagnostic log verbosity (Diagnostic Log plan, Task 2). Default
    /// `.off` — the sink (`DiagnosticLog`) writes nothing until this is
    /// turned up in Settings → General. `MacSCPApp` reads this at launch and
    /// again on every change to (re)configure `DiagnosticLog.shared`. Same
    /// raw-value-backed, unrecognized-value-falls-back-to-default shape as
    /// `checksumAlgorithm` above: a future app version's level, or a
    /// hand-edited `settings.json`, reads back as `.off` rather than as a
    /// guessed level.
    public var diagnosticLogLevel: DiagnosticLogLevel {
        get {
            guard case .string(let value)? = raw[Keys.diagnosticLogLevel] else {
                return Defaults.diagnosticLogLevel
            }
            return DiagnosticLogLevel(rawValue: value) ?? Defaults.diagnosticLogLevel
        }
        set {
            raw[Keys.diagnosticLogLevel] = .string(newValue.rawValue)
            persist()
        }
    }

    /// The UI catalog chosen in Settings. `.system` follows the OS preference.
    /// Applied at launch through LocalizationContext; changes need a relaunch.
    public var selectedLanguage: AppLanguage {
        get {
            guard case .string(let value)? = raw[Keys.appLanguage] else {
                return .system
            }
            return AppLanguage(rawValue: value) ?? .system
        }
        set {
            raw[Keys.appLanguage] = .string(newValue.rawValue)
            persist()
        }
    }

    /// Whether the "external terminals can't receive a saved password" hint
    /// (M11d) has already been dismissed with "Don't show again". Default
    /// OFF (unshown) — the hint appears once, then never again once this
    /// flips true.
    public var externalTerminalPasswordHintShown: Bool {
        get { boolValue(for: Keys.externalTerminalPasswordHintShown, default: false) }
        set { setBool(newValue, for: Keys.externalTerminalPasswordHintShown) }
    }

    /// Which columns the file list displays (M11m). `name` is always
    /// included in what this returns, regardless of what's stored — it can
    /// never be toggled off (`FileColumn.isToggleable`). Forward-compatible:
    /// a `settings.json` predating this feature (missing key entirely) falls
    /// back to `FileColumn.defaultVisible`'s set — the three fixed columns
    /// the list always showed before this feature existed. Type and the
    /// other optional columns are enabled through Preferences. Any
    /// install that has already persisted an explicit `visibleColumns`
    /// array — even once, for an unrelated column — is unaffected by that:
    /// this fallback only fires when the key is missing entirely.
    /// Unrecognized raw column names on disk (a future app version's
    /// column, or hand-edited garbage) are dropped silently rather than
    /// crashing or surfacing them as garbage. Written back out in
    /// `FileColumn.allCases` order for a stable, readable settings.json —
    /// the Set itself carries no ordering guarantee.
    public var visibleColumns: Set<FileColumn> {
        get {
            guard case .array(let values)? = raw[Keys.visibleColumns] else {
                return Self.defaultVisibleColumns
            }
            var result: Set<FileColumn> = []
            for value in values {
                guard case .string(let rawColumn) = value,
                    let column = FileColumn(rawValue: rawColumn)
                else { continue }
                result.insert(column)
            }
            result.insert(.name)
            return result
        }
        set {
            var columns = newValue
            columns.insert(.name)
            raw[Keys.visibleColumns] = .array(
                FileColumn.allCases.filter(columns.contains).map { .string($0.rawValue) })
            persist()
        }
    }

    private static var defaultVisibleColumns: Set<FileColumn> {
        Set(FileColumn.allCases.filter(\.defaultVisible))
    }

    /// How wide the session sidebar opens, in points. Written back after the
    /// user drags the split divider, so the width the window comes up with
    /// is the width that window was left at.
    ///
    /// Clamped to `sidebarWidthRange` on BOTH ends, same forward-compat
    /// pattern as `autoRefreshIntervalSeconds`: a width typed into
    /// settings.json by hand cannot open a sidebar too narrow to read a
    /// session name in, nor one so wide the file browser has nowhere left
    /// to go. Fresh settings default to a compact 180-point sidebar;
    /// explicitly saved widths remain unchanged.
    public var sidebarWidth: Int {
        get {
            clamp(
                intValue(for: Keys.sidebarWidth, default: Defaults.sidebarWidth),
                Self.sidebarWidthRange.lowerBound, Self.sidebarWidthRange.upperBound)
        }
        set {
            setInt(
                clamp(newValue, Self.sidebarWidthRange.lowerBound, Self.sidebarWidthRange.upperBound),
                for: Keys.sidebarWidth)
        }
    }

    /// The bounds `sidebarWidth` clamps to, reachable without a
    /// `SettingsStore` instance for the same reason
    /// `defaultConnectTimeoutSeconds` is: the sidebar's own frame is built
    /// from these two numbers, and a frame that repeated them as literals
    /// could drift from the clamp that decides what a stored width means.
    ///
    /// The floor is the frame minimum the sidebar has always had, which this
    /// task left alone. The ceiling is arithmetic rather than taste: a
    /// connected window holds its content to a minimum width of 930 and the
    /// detail pane beside the sidebar to a minimum of 590, leaving 340
    /// points for the sidebar in the narrowest window the user can drag the
    /// window itself to. A larger stored width would be a width no window
    /// could ever show. (The split divider takes a point out of those 340,
    /// so at exactly that narrowest window the sidebar comes to rest one
    /// point below the ceiling; every wider window reaches it.)
    ///
    /// A window in its pristine state — a single unconnected tab, content
    /// minimum 700 against a 500-point detail minimum — has only 200 points
    /// to give, so a sidebar near this ceiling IS squeezed while the window
    /// is in that state. Deliberately not a second, smaller ceiling: the
    /// squeeze lasts as long as the window is that small, and what keeps it
    /// from being mistaken for something the user asked for is the App
    /// layer's recording rule, not this range.
    public nonisolated static let sidebarWidthRange: ClosedRange<Int> = 170...340

    public var presignedDefaultExpiry: PresignedExpiry {
        get {
            guard case .string(let value)? = raw[Keys.presignedDefaultExpiry] else {
                return Defaults.presignedDefaultExpiry
            }
            return PresignedExpiry(rawValue: value) ?? .oneHour
        }
        set {
            raw[Keys.presignedDefaultExpiry] = .string(newValue.rawValue)
            persist()
        }
    }

    public var checksumAlgorithm: ChecksumAlgorithm {
        get {
            guard case .string(let value)? = raw[Keys.checksumAlgorithm] else {
                return Defaults.checksumAlgorithm
            }
            return ChecksumAlgorithm(rawValue: value) ?? Defaults.checksumAlgorithm
        }
        set {
            raw[Keys.checksumAlgorithm] = .string(newValue.rawValue)
            persist()
        }
    }

    public var reconnectBehaviour: ReconnectBehaviour {
        get {
            guard case .string(let value)? = raw[Keys.reconnectBehaviour] else {
                return Defaults.reconnectBehaviour
            }
            return ReconnectBehaviour(rawValue: value) ?? .offerOnly
        }
        set {
            raw[Keys.reconnectBehaviour] = .string(newValue.rawValue)
            persist()
        }
    }

    /// Whether optional non-TLS idle-connection probes run. TLS maintenance
    /// remains enabled independently. Its own Bool, like
    /// `autoRefreshEnabled`: the interval below never carries "off".
    ///
    /// Files written before 2026-09-02 stored "off" as `keepAliveIntervalSeconds
    /// == 0` and had no key for this. Read-side migration, once: when this key
    /// is ABSENT and the stored interval is `0`, the answer is `false`. Nothing
    /// is rewritten until the user changes a setting.
    public var keepAliveEnabled: Bool {
        get {
            if let stored = optionalBool(for: Keys.keepAliveEnabled) { return stored }
            return intValue(for: Keys.keepAliveIntervalSeconds, default: Defaults.keepAliveIntervalSeconds) != 0
        }
        set { setBool(newValue, for: Keys.keepAliveEnabled) }
    }

    /// Seconds between liveness probes; default 60. Clamped to 15...600 on
    /// BOTH ends, same forward-compat pattern as `autoRefreshIntervalSeconds`
    /// — optional non-TLS probes use `keepAliveEnabled`; TLS maintenance
    /// uses a separate ten-second cap even when that toggle is off, so
    /// this value never needs to carry "off" and a hand-edited settings.json
    /// cannot produce a runaway or dead probe.
    ///
    /// A stored `0` is the retired sentinel, not an interval: this getter
    /// reads it as the default `60` rather than clamping it to the floor
    /// `15`. Surfacing the floor as "your interval" for a file that never
    /// meant one — an old off file, or a hand-edited `0` — would just be a
    /// new surprise in place of the old one.
    public var keepAliveIntervalSeconds: Int {
        get {
            let stored = intValue(for: Keys.keepAliveIntervalSeconds, default: Defaults.keepAliveIntervalSeconds)
            return stored == 0 ? Defaults.keepAliveIntervalSeconds : clamp(stored, 15, 600)
        }
        set { setInt(clamp(newValue, 15, 600), for: Keys.keepAliveIntervalSeconds) }
    }

    public var connectTimeoutSeconds: Int {
        get {
            clamp(
                intValue(for: Keys.connectTimeoutSeconds, default: Defaults.connectTimeoutSeconds),
                5, 120)
        }
        set { setInt(clamp(newValue, 5, 120), for: Keys.connectTimeoutSeconds) }
    }

    /// The throughput test's payload in MiB (`DiagnosticScope.throughput`) —
    /// default 2, clamped on BOTH ends to
    /// `DiagnosticThroughputSettings.payloadMiBRange` (1–256), so a
    /// hand-edited settings.json can neither ask for an empty payload nor
    /// move gigabytes through somebody's server.
    public var throughputPayloadMiB: Int {
        get {
            clamp(
                intValue(for: Keys.throughputPayloadMiB, default: Defaults.throughputPayloadMiB),
                Self.throughputPayloadMiBRange.lowerBound,
                Self.throughputPayloadMiBRange.upperBound)
        }
        set {
            setInt(
                clamp(
                    newValue, Self.throughputPayloadMiBRange.lowerBound,
                    Self.throughputPayloadMiBRange.upperBound),
                for: Keys.throughputPayloadMiB)
        }
    }

    /// The range `throughputPayloadMiB` clamps to, reachable without an
    /// instance so the Settings stepper is built from the same two numbers.
    public nonisolated static let throughputPayloadMiBRange =
        DiagnosticThroughputSettings.payloadMiBRange

    /// The same default as the instance property above, reachable without a
    /// `SettingsStore` instance. `MacSCPCLI` never reads user settings at
    /// all (it has no `settings.json` of its own) and this task does not
    /// change that — `SessionConnecting.swift`'s `connect` uses this
    /// constant so its connect-timeout matches the App's default instead of
    /// duplicating the literal `10` a second time somewhere easy to drift.
    public nonisolated static let defaultConnectTimeoutSeconds = Defaults.connectTimeoutSeconds

    /// Convenience: association lookup with the SAME normalization applied.
    public func associatedApp(forExtension ext: String) -> String? {
        let normalizedExtension = Self.normalizeExtension(ext)
        guard !normalizedExtension.isEmpty else { return nil }
        return fileAssociations[normalizedExtension]
    }

    /// Normalizes a file extension for use as a `fileAssociations` key:
    /// trims whitespace, strips a single leading dot, and lowercases.
    private static func normalizeExtension(_ ext: String) -> String {
        var trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        return trimmed.lowercased()
    }

    // MARK: - Backing access

    private func intValue(for key: String, default defaultValue: Int) -> Int {
        guard case .number(let value)? = raw[key] else {
            return defaultValue
        }
        return Int(value)
    }

    private func setInt(_ value: Int, for key: String) {
        raw[key] = .number(Double(value))
        persist()
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }

    /// Generic string-optional backing (same nil/empty-collapsing rule as
    /// `defaultEditorPath`'s hand-rolled getter/setter): empty and missing
    /// both read as `nil`, and setting `nil` or "" clears the key.
    private func stringValue(for key: String) -> String? {
        guard case .string(let value)? = raw[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private func setString(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            raw[key] = .string(value)
        } else {
            raw[key] = nil
        }
        persist()
    }

    private func boolValue(for key: String, default defaultValue: Bool) -> Bool {
        guard case .bool(let value)? = raw[key] else {
            return defaultValue
        }
        return value
    }

    private func setBool(_ value: Bool, for key: String) {
        raw[key] = .bool(value)
        persist()
    }

    /// Like `boolValue`, but distinguishes "key absent" (`nil`) from
    /// "key present and `false`" — `boolValue` collapses both to its
    /// `defaultValue` and can't tell them apart. Needed for a read-side
    /// migration that only fires when the key is truly absent.
    private func optionalBool(for key: String) -> Bool? {
        guard case .bool(let value)? = raw[key] else {
            return nil
        }
        return value
    }

    /// Writes the entire raw backing (including unknown keys) back out
    /// synchronously — mirroring `SessionStore`'s save approach. Creates the
    /// directory if needed; write errors are swallowed (setters can't throw
    /// per the public interface).
    private func persist() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
