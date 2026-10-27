import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// One row in the Settings window's sidebar (M18/T7). Each case owns its own
/// SF Symbol and localized title, and maps 1:1 to a section `struct` rendered
/// in the detail column by `SettingsView.body`'s `switch`.
enum SettingsSection: Hashable {
    case general
    case startup
    case security
    case appearance
    case transfers
    case openWith
    case terminal
    case shortcuts
    case whatsNew
    case manageData
    case ssh
    case s3

    var title: String {
        switch self {
        case .general: return L10n.string("settings.tab.general", "General")
        case .startup: return L10n.string("settings.section.startup", "Startup")
        case .security: return L10n.string("credentials.settings.title", "Security")
        case .appearance: return L10n.string("settings.section.appearance", "View")
        case .transfers: return L10n.string("settings.tab.transfers", "Transfers")
        case .openWith: return L10n.string("settings.tab.openWith", "Open with")
        case .terminal: return L10n.string("settings.tab.terminal", "Terminal")
        case .shortcuts: return L10n.string("settings.tab.shortcuts", "Shortcuts")
        case .whatsNew: return L10n.string("settings.tab.whatsNew", "What's new")
        case .manageData: return L10n.string("settings.section.manageData", "Manage Data")
        case .ssh: return L10n.string("settings.section.ssh", "SSH")
        case .s3: return L10n.string("settings.section.s3", "S3")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .startup: return "power"
        case .security: return "lock.shield"
        case .appearance: return "eye"
        case .transfers: return "arrow.up.arrow.down"
        case .openWith: return "doc.badge.gearshape"
        case .terminal: return "terminal"
        case .shortcuts: return "keyboard"
        case .whatsNew: return "sparkles"
        case .manageData: return "archivebox"
        case .ssh: return "key"
        case .s3: return "cloud"
        }
    }
}
/// Settings detail embedded in the main window. Its section selection belongs
/// to the window, alongside the shared sidebar; preference stores remain live.
struct SettingsView: View {
    static let minimumWidth: CGFloat = 680

    var store: SettingsStore
    /// The language in effect when this process launched (M11p) — threaded
    /// through from `MacSCPApp.init` to `GeneralSettingsSection`, which
    /// compares it against the live `store.selectedLanguage` to decide
    /// whether to show the relaunch button.
    var launchLanguage: AppLanguage
    /// Command bridge to the main window (M8a/T4), threaded through for the
    /// "Manage Data" section only: two of its five entries must reach the
    /// sheets the main window already presents rather than open a second
    /// copy here (see `ManageDataSettingsSection`).
    var settingsBridge: SettingsWindowBridge

    @Binding var selection: SettingsSection?

    var body: some View {
        Group {
            switch selection ?? .general {
            case .general:
                GeneralSettingsSection(store: store, launchLanguage: launchLanguage)
            case .startup:
                StartupSettingsSection(store: store)
            case .security:
                CredentialSettingsSection()
            case .appearance:
                AppearanceSettingsSection(store: store)
            case .transfers:
                TransfersSettingsTab(store: store)
            case .openWith:
                OpenWithSettingsTab(store: store)
            case .terminal:
                TerminalSettingsTab(store: store)
            case .shortcuts:
                ShortcutsSettingsTab()
            case .whatsNew:
                WhatsNewSettingsSection()
            case .manageData:
                ManageDataSettingsSection(settingsBridge: settingsBridge)
            case .ssh:
                SSHSettingsSection(store: store)
            case .s3:
                S3SettingsSection(store: store)
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Uses the main window's shared split pane and the same fixed navigation bar.
enum SettingsNavigationGroup: String, CaseIterable, Identifiable {
    case application, workflow, protocols, maintenance
    var id: Self { self }
    var title: String { L10n.string("settings.navigation.\(rawValue)", rawValue) }
    var sections: [SettingsSection] {
        switch self {
        case .application: [.general, .startup, .security, .appearance]
        case .workflow: [.transfers, .openWith, .terminal, .shortcuts]
        case .protocols: [.ssh, .s3]
        case .maintenance: [.manageData, .whatsNew]
        }
    }
}

struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection?
    var onSessions: () -> Void
    var onTunnels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarWorkspaceHeading(title: L10n.string("sidebar.settings", "Settings"))
            SidebarList {
                ForEach(SettingsNavigationGroup.allCases) { group in
                    if group != .application { Divider().padding(.horizontal, 6).padding(.top, 10) }
                    SidebarGroupTitle(name: group.title)
                        .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 6)
                    ForEach(group.sections, id: \.self) { section in
                        sectionButton(section)
                    }
                }
            }
        }
        .background(DesignTokens.sidebarSurface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SessionSidebarToolbar(showsSettings: true, onSessions: onSessions, onTunnels: onTunnels)
        }
    }

    private func sectionButton(_ section: SettingsSection) -> some View {
        Button { selection = section } label: {
            SidebarNavigationLabel(title: section.title, symbol: section.systemImage)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help(section.title)
        .listRowBackground(selection == section ? DesignTokens.remoteBlue.opacity(0.12) : .clear)
    }
}

/// Launch behavior is separate from general preferences and profile editing.
private struct StartupSettingsSection: View {
    @Bindable var store: SettingsStore
    @State private var loginItem = LoginItemModel()
    @State private var showTunnelAutostartSheet = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("tunnel.autostart.loginItem", "Open MacSCP at login"),
                    isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }))
                Text(TunnelAutostartSheet.statusText(loginItem.status))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Toggle(
                    L10n.string(
                        "settings.general.restoreWindows", "Restore windows at launch"),
                    isOn: $store.restoresWindows)
            } footer: {
                Text(L10n.string(
                    "settings.general.restoreWindows.footer",
                    "Windows and their tabs come back as they were, disconnected. "
                        + "Nothing connects until you do."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(L10n.string("settings.startup.tunnels.configure", "Configure automatic tunnels…")) {
                    showTunnelAutostartSheet = true
                }
            } header: {
                L10n.text("settings.startup.tunnels", "Automatic tunnels")
            } footer: {
                L10n.text("settings.startup.tunnels.footer", "Choose which tunnels start when MacSCP opens or when macOS launches it at login. This does not enable opening MacSCP at login.")
            }
        }
        .formStyle(.grouped).padding()
        .sheet(isPresented: $showTunnelAutostartSheet) {
            TunnelAutostartSheet(manager: TunnelManager.shared, onClose: { showTunnelAutostartSheet = false })
        }
    }
}

/// General application preferences; launch behavior lives in Startup.
private struct GeneralSettingsSection: View {
    @Environment(\.applicationUpdater) private var updater
    @Bindable var store: SettingsStore
    /// The language in effect when this process launched (M11p) — compared
    /// against the live `store.selectedLanguage` below to decide whether the
    /// relaunch button is shown (a language change only takes effect on a
    /// fresh launch).
    var launchLanguage: AppLanguage

    /// Shared packaged/source metadata, also used by the About window.
    private var currentVersionText: String {
        ReleaseMetadata().version
            ?? L10n.string("settings.general.currentVersion.unknown", "Unknown")
    }

    private var updatePresentation: AppUpdatePolicy.SettingsPresentation {
        updater?.settingsPresentation ?? AppUpdatePolicy.settingsPresentation(
            distribution: Bundle.main.object(forInfoDictionaryKey: "MacSCPDistribution") as? String,
            isPackagedApplication: Bundle.main.bundleURL.pathExtension == "app",
            isConfigured: false)
    }

    /// Where `DiagnosticLog` writes its files — read off the sink's own
    /// `defaultDirectory` rather than recomputed here, so this row and the
    /// sink can never disagree about the path it shows/reveals.
    private var diagnosticLogDirectory: URL { DiagnosticLog.defaultDirectory }

    /// Creates the log folder if it does not exist yet (a level of `.off`
    /// never created it) and reveals it in Finder — the same
    /// create-then-reveal shape a first-run "Show in Finder" needs anywhere
    /// there is no guarantee the target already exists.
    private func revealDiagnosticLogFolder() {
        try? FileManager.default.createDirectory(
            at: diagnosticLogDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([diagnosticLogDirectory])
    }

    var body: some View {
        Form {
            // Persist the next launch's catalog choice. Keep the relaunch
            // button visible until that choice is actually applied.
            Section {
                Picker(
                    L10n.string("settings.general.language.header", "Language"),
                    selection: $store.selectedLanguage
                ) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(L10n.string(language.titleKey, language.rawValue))
                            .tag(language)
                    }
                }
                if store.selectedLanguage != launchLanguage {
                    Button(L10n.string("settings.general.language.relaunch", "Relaunch MacSCP")) {
                        AppRelauncher.relaunch()
                    }
                }
            } footer: {
                Text(L10n.string(
                    "settings.general.language.footer",
                    "Takes effect after a relaunch."))
                    .foregroundStyle(.secondary)
            }

            // Menu-bar status item toggle (M11n): the AppKit
            // `MenuBarController` observes this same `store.menuBarEnabled`
            // and installs/removes the `NSStatusItem` live.
            Section {
                Toggle(
                    L10n.string("settings.general.menubar", "Show menu bar icon"),
                    isOn: $store.menuBarEnabled)
            }

            // Notifications (next build of 2026-09-17, Task 7): one switch
            // for all three macOS notifications — a lost connection, a
            // failed transfer, a failed port forwarding.
            Section {
                Toggle(
                    L10n.string("settings.general.notifications", "Notifications"),
                    isOn: $store.notificationsEnabled)
            } footer: {
                Text(L10n.string(
                    "settings.general.notifications.footer",
                    "A macOS notification when a connection is lost, a transfer fails or a "
                        + "port forwarding fails. Shown only while MacSCP is in the background "
                        + "or the window concerned is not in front."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.string("settings.diagnostics.system", "Collect server system information"),
                       isOn: $store.diagnosticSystemInformation)
                Toggle(L10n.string("settings.diagnostics.public", "Look up the server's public IP addresses"),
                       isOn: $store.diagnosticPublicAddresses)
            } header: {
                L10n.text("diagnostics.title", "Connection diagnostics")
            } footer: {
                L10n.text("settings.diagnostics.footer", "System information is read on the connected server without administrator privileges. Public IP lookup is optional and contacts ipify, OpenDNS or Google DNS; no credentials are sent.")
            }

            Section {
                LabeledContent(L10n.string("settings.general.currentVersion", "Current version")) {
                    Text(currentVersionText)
                        .foregroundStyle(.secondary)
                }
                if let updater, updatePresentation == .github {
                    Toggle(L10n.string("updates.automatic", "Check for updates automatically"),
                        isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                    Button(L10n.string("updates.check", "Check for Updates…")) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } else if updatePresentation != .appStore {
                    Link(L10n.string("updates.download", "View GitHub releases"),
                         destination: URL(string: "https://github.com/retrotools-apps/MacSCP/releases")!)
                        .buttonStyle(.polished)
                }
            } header: {
                L10n.text("updates.title", "Updates")
            } footer: {
                Group {
                    switch updatePresentation {
                    case .github:
                        L10n.text("updates.footer", "Updates are downloaded from GitHub and verified before installation. Installation and relaunch require your confirmation.")
                    case .appStore:
                        L10n.text("settings.general.appStoreUpdates", "Mac App Store installations are updated through the Store, according to its automatic update settings.")
                    case .localBuild:
                        L10n.text("updates.localBuild", "This is a local build. Rebuild it from source, or install the GitHub version to receive updates.")
                    case .unavailable:
                        L10n.text("updates.unconfigured", "The updater could not be initialized. Download the latest version from GitHub.")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            diagnosticLogSection
        }
        .formStyle(.grouped)
        .padding()
    }

    /// The "Diagnostic log" row (Diagnostic Log plan, Task 2): a level
    /// picker, the folder path as a caption, and a "Show in Finder" button.
    /// `MacSCPApp` reconfigures `DiagnosticLog.shared` from `store
    /// .diagnosticLogLevel` at launch and on every change to this picker
    /// (see `MacSCPApp.body`'s `.onChange`) — this row only owns the
    /// setting and the folder-reveal affordance, never the sink itself.
    ///
    /// Its own computed property, not inlined into `body`'s `Form` like the
    /// rows above it: unlike every other row here, TWO of its `Text(`s
    /// legitimately take a hardcoded literal that must never route through
    /// `L10n.string(`. The language picker has its own localized entries
    /// and lives in a separate section, so the
    /// source-scanning guard that forbids a hardcoded `Text(` literal
    /// anywhere in the row needs a span that is exactly this row and
    /// nothing else, which only a named declaration gives a
    /// `declarationBodyRange(of:in:)` scan (`SettingsViewDiagnosticLogGuardTests`).
    @ViewBuilder
    private var diagnosticLogSection: some View {
        Section {
            Picker(
                L10n.string("settings.general.diagnosticLog", "Diagnostic log"),
                selection: $store.diagnosticLogLevel
            ) {
                Text(L10n.string("settings.general.diagnosticLog.off", "Off"))
                    .tag(DiagnosticLogLevel.off)
                Text(L10n.string("settings.general.diagnosticLog.errors", "Errors"))
                    .tag(DiagnosticLogLevel.error)
                Text(L10n.string("settings.general.diagnosticLog.info", "Info"))
                    .tag(DiagnosticLogLevel.info)
                Text(L10n.string("settings.general.diagnosticLog.debug", "Debug"))
                    .tag(DiagnosticLogLevel.debug)
            }
            HStack {
                Text(diagnosticLogDirectory.path(percentEncoded: false))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("settings.general.diagnosticLog.reveal", "Show in Finder")) {
                    revealDiagnosticLogFolder()
                }
                .buttonStyle(.polished)
            }
        } footer: {
            Text(L10n.string(
                "settings.general.diagnosticLogHint",
                "Off by default, including system and session audit logs. Writes no passwords, keys or file contents."))
                .foregroundStyle(.secondary)
        }
    }
}

/// "View" options (M18/T7; split out of the former `GeneralSettingsTab`):
/// the hidden-files toggle, the file-list column checkboxes (M11m/T2), the
/// sidebar tag-filter toggle (E1), and the auto-refresh toggle/interval
/// (M9c).
private struct AppearanceSettingsSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    L10n.string("settings.general.showHidden", "Show hidden files"),
                    isOn: $store.showHiddenFiles)
            } footer: {
                Text(L10n.string(
                    "settings.general.showHiddenHint",
                    "Applies to both panes. Shortcut: ⌘⇧."))
                    .foregroundStyle(.secondary)
            }

            // File-list columns (M11m/T2): one checkbox per toggleable
            // `FileColumn` — `name` is excluded (`FileColumn.isToggleable`
            // is `false` only for it), so it never gets a row here and stays
            // permanently shown, matching `SettingsStore.visibleColumns`'s
            // own always-includes-`name` guarantee. Titles are the SAME
            // localized strings the table's own column headers use
            // (`FileColumn.localizedTitle`, `RemoteFileTableView.swift`), so
            // a box's label always matches what the user sees atop the
            // table it controls.
            Section {
                ForEach(FileColumn.allCases.filter(\.isToggleable), id: \.self) { column in
                    Toggle(column.localizedTitle, isOn: Binding(
                        get: { store.visibleColumns.contains(column) },
                        set: { isOn in
                            var columns = store.visibleColumns
                            if isOn {
                                columns.insert(column)
                            } else {
                                columns.remove(column)
                            }
                            store.visibleColumns = columns
                        }
                    ))
                }
            } header: {
                Text(L10n.string("settings.general.columns.header", "File List Columns"))
            } footer: {
                Text(L10n.string(
                    "settings.general.columns.footer",
                    "Applies to both panes. Name is always shown."))
                    .foregroundStyle(.secondary)
            }

            // Compact sidebar mode (sidebar-polish plan, Task 2): tighter
            // row padding, nothing else — `SessionSidebar`
            // reads this as a plain presentation preference
            // above, as a plain fact handed down from `ContentView`.
            Section {
                Toggle(
                    L10n.string("settings.appearance.sidebarCompact", "Compact sidebar"),
                    isOn: $store.sidebarCompact)
            }

            Section {
                Picker(L10n.string("settings.appearance.contrast", "Contrast"), selection: $store.highContrast) {
                    Text(L10n.string("settings.appearance.lowContrast", "Low contrast")).tag(false)
                    Text(L10n.string("settings.appearance.highContrast", "High contrast")).tag(true)
                }
                .pickerStyle(.segmented)
                Toggle(L10n.string("settings.appearance.groupColors", "Color group backgrounds"),
                       isOn: $store.groupColorsEnabled)
            } footer: {
                Text(L10n.string("settings.appearance.groupColors.footer",
                    "When disabled, group backgrounds and cards use alternating translucent grays. Saved colors are preserved."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    L10n.string("settings.general.autoRefresh", "Auto-refresh remote view"),
                    isOn: $store.autoRefreshEnabled)
                Stepper(
                    value: Binding(
                        get: { store.autoRefreshIntervalSeconds },
                        set: { store.autoRefreshIntervalSeconds = $0 }
                    ),
                    in: 2...300
                ) {
                    Text(String(
                        format: L10n.string(
                            "settings.general.autoRefreshInterval %lld", "Every %lld seconds"),
                        store.autoRefreshIntervalSeconds))
                }
                .disabled(!store.autoRefreshEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// The single "Transfers" section: concurrency limit, bandwidth limits, and
/// the checksum procedure — computing a checksum reads the whole file on the
/// far side, so it is asked for and cancelled like any other transfer. The
/// S3 presigned-link-expiry section moved to the protocol-specific
/// `S3SettingsSection` in M18/T7.
private struct TransfersSettingsTab: View {
    var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: Binding(
                        get: { store.maxConcurrentTransfers },
                        set: { store.maxConcurrentTransfers = $0 }
                    ),
                    in: 1...8
                ) {
                    HStack {
                        Text(L10n.string("settings.maxConcurrent.label", "Maximum concurrent transfers"))
                        Spacer()
                        Text("\(store.maxConcurrentTransfers)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text(L10n.string(
                    "settings.maxConcurrent.footer",
                    "Applies to new transfers; running ones are unaffected."))
                    .foregroundStyle(.secondary)
            }

            // Full paths on every row (dev-build follow-up, 2026-09-03): off
            // by default, so the queue bar stays as compact as it always
            // has been until this is switched on. `TransferQueueBar` reads
            // the flag directly off `store` and renders the same
            // `TransferRowPaths` strings the hover hint already shows.
            Section {
                Toggle(
                    L10n.string("settings.transfers.showFullPaths", "Always show full paths"),
                    isOn: Binding(
                        get: { store.transfersShowFullPaths },
                        set: { store.transfersShowFullPaths = $0 }
                    ))
            }

            // NOTE (bandwidth-row duplicate-value bug, fixed): `TextField(_
            // titleKey:value:format:)`'s title is NOT a placeholder inside a
            // `Form` styled `.formStyle(.grouped)` - macOS renders it as a
            // permanent label next to the field (same treatment as
            // `Toggle`/`Picker`/`Stepper` titles). The previous code passed
            // "0" as the title, so the row showed "Upload  0  <field: 0>" -
            // the literal "0" label duplicating the real (also-zero-by-
            // default) bound value. Fix: empty title (the outer
            // `LabeledContent` already supplies "Upload"/"Download" as the
            // row label) plus an explicit "KB/s" unit suffix.
            Section {
                LabeledContent(L10n.string("settings.bandwidth.upload", "Upload")) {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: Binding(
                                get: { store.uploadLimitKBs },
                                set: { store.uploadLimitKBs = $0 }
                            ), format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        // Empty title (grouped-Form label trap) — restore the
                        // VoiceOver label explicitly (M9d final review).
                        .accessibilityLabel(L10n.string("settings.bandwidth.upload", "Upload"))
                        // Unit abbreviation, not prose - no localization key
                        // needed (see SettingsView doc comment / task notes).
                        Text(verbatim: "KB/s")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L10n.string("settings.bandwidth.download", "Download")) {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: Binding(
                                get: { store.downloadLimitKBs },
                                set: { store.downloadLimitKBs = $0 }
                            ), format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(L10n.string("settings.bandwidth.download", "Download"))
                        Text(verbatim: "KB/s")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.string("settings.bandwidth.header", "Bandwidth limit upload/download"))
            } footer: {
                Text(L10n.string("settings.bandwidth.footer", "0 = unlimited"))
                    .foregroundStyle(.secondary)
            }

            // The diagnostics throughput test's payload (plan of
            // 2026-09-19). Here, under the bandwidth limits, because the test
            // IS a transfer — paced by those limits — and this is where a
            // reader looks for what moves how much. The range is the
            // diagnosis's own (`SettingsStore.throughputPayloadMiBRange`).
            Section {
                Stepper(
                    value: Binding(
                        get: { store.throughputPayloadMiB },
                        set: { store.throughputPayloadMiB = $0 }
                    ),
                    in: SettingsStore.throughputPayloadMiBRange
                ) {
                    HStack {
                        Text(L10n.string("settings.throughput.payload", "Test file size"))
                        Spacer()
                        // Unit abbreviation, not prose — the "KB/s" rule
                        // above.
                        Text(verbatim: "\(store.throughputPayloadMiB) MiB")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text(L10n.string("settings.throughput.header", "Throughput test"))
            } footer: {
                Text(L10n.string(
                    "settings.throughput.footer",
                    """
                    The throughput test in Connection diagnostics uploads a file of this \
                    size to the server, downloads it and deletes it.
                    """))
                    .foregroundStyle(.secondary)
            }

            // Checksums live here because computing one IS a transfer: it
            // reads the whole file on the far side, takes minutes on a
            // large one, and is asked for and cancelled like any other.
            //
            // The order is `ChecksumAlgorithm.allCases`, which starts at
            // the preferred one, and the marker on the other two is read
            // off `isCryptographicallyBroken` rather than from a list kept
            // here — so an algorithm added later arrives already labelled
            // or already unlabelled, whichever it deserves, without this
            // view being told about it.
            Section {
                Picker(
                    L10n.string("settings.checksum.algorithm", "Checksum algorithm"),
                    selection: Binding(
                        get: { store.checksumAlgorithm },
                        set: { store.checksumAlgorithm = $0 }
                    )
                ) {
                    ForEach(ChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(label(for: algorithm)).tag(algorithm)
                    }
                }
            } header: {
                Text(L10n.string("settings.checksum.header", "Checksums"))
            } footer: {
                Text(L10n.string(
                    "settings.checksum.footer",
                    """
                    SHA-256 is the default. MD5 and SHA-1 are offered because a figure \
                    published elsewhere is often one of them: they serve to compare a file \
                    against such a figure, never as proof that two files are the same.
                    """))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// A broken procedure is still offered — it is what a published figure
    /// is often written in — but it is not offered as an equal. The suffix
    /// is what says so in the list itself, where the choice is made, rather
    /// than only in the footer below it.
    private func label(for algorithm: ChecksumAlgorithm) -> String {
        guard algorithm.isCryptographicallyBroken else { return algorithm.displayName }
        return algorithm.displayName + " — " + L10n.string(
            "settings.checksum.forComparisonOnly", "for comparison only")
    }
}

/// The "Open with" section (M5e/T2): the default editor used for remote
/// files without a matching extension rule, and per-extension overrides.
private struct OpenWithSettingsTab: View {
    var store: SettingsStore

    /// Which `.fileImporter` is currently active: the default-editor picker,
    /// or the picker for a specific extension rule (new or existing).
    private enum ActivePicker: Identifiable {
        case defaultEditor
        case rule(extension: String)

        var id: String {
            switch self {
            case .defaultEditor: return "defaultEditor"
            case .rule(let ext): return "rule:\(ext)"
            }
        }
    }

    @State private var activePicker: ActivePicker?
    /// Drives the shared `.fileImporter`. Kept separate from `activePicker`
    /// because SwiftUI resets the `isPresented` binding before invoking the
    /// completion handler — deriving presentation from `activePicker` would
    /// nil the picker context out from under the handler and drop the
    /// selection.
    @State private var importerPresented = false
    /// The extension being typed into the "add rule" row.
    @State private var newRuleExtension: String = ""

    /// Mirrors `SettingsStore`'s private extension normalization (trim,
    /// strip one leading dot, lowercase) so the Choose-app button gates on
    /// what the store would actually KEEP — "." trims non-empty but
    /// normalizes to empty and would be silently dropped (M9d final review).
    private var normalizedNewRuleExtension: String {
        var trimmed = newRuleExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed.lowercased()
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(appDisplayName(forPath: store.defaultEditorPath))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("settings.openWith.choose", "Choose…")) {
                        activePicker = .defaultEditor
                        importerPresented = true
                    }
                    Button(L10n.string("settings.openWith.reset", "Reset")) {
                        store.defaultEditorPath = nil
                    }
                    .disabled(store.defaultEditorPath == nil)
                }
            } header: {
                Text(L10n.string("settings.openWith.defaultEditor.header", "Default editor"))
            }

            Section {
                let sortedAssociations = store.fileAssociations.sorted { $0.key < $1.key }
                ForEach(sortedAssociations, id: \.key) { extensionKey, appPath in
                    HStack {
                        Text(".\(extensionKey)")
                            .frame(width: 60, alignment: .leading)
                        Text(appDisplayName(forPath: appPath))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            var associations = store.fileAssociations
                            associations[extensionKey] = ""
                            store.fileAssociations = associations
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        // `.accessibilityLabel` and `.help` are different affordances,
                        // not a duplication: the former labels the control for
                        // VoiceOver, the latter produces the hover tooltip. Both are
                        // needed and intentionally share the same key.
                        .accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))
                        .help(L10n.string("settings.openWith.rules.remove", "Remove"))
                    }
                }

                // ROOT CAUSE (button-looked-disabled bug, fixed): as with
                // the bandwidth rows above, a `TextField`'s title is a
                // permanent label in a `.formStyle(.grouped)` Form, NOT an
                // empty-state placeholder. Passing the example text "php" as
                // the title made it appear PERMANENTLY next to the field -
                // identical whether or not the user had typed anything -
                // so an untouched, still-empty field looked already filled
                // in with "php". The "Choose app..." disabled condition
                // below was always correct (it reflects the real, empty
                // `newRuleExtension`); the field's misleading label just
                // masked that nothing had actually been typed. Fix: empty
                // title + the real `prompt:` parameter, which IS a true
                // dimmed hint shown only while the field is empty and
                // disappears once real text is entered.
                LabeledContent(L10n.string("settings.openWith.rules.extension", "Extension")) {
                    HStack {
                        TextField(
                            "", text: $newRuleExtension,
                            prompt: Text(L10n.string("settings.openWith.rules.extensionPlaceholder", "php"))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .accessibilityLabel(L10n.string("settings.openWith.rules.extension", "Extension"))
                        Button(L10n.string("settings.openWith.rules.chooseApp", "Choose app…")) {
                            activePicker = .rule(extension: newRuleExtension)
                            importerPresented = true
                        }
                        // Gate on the NORMALIZED value (M9d final review):
                        // "." trims to non-empty but normalizes to empty, so
                        // the store's setter would silently drop the rule.
                        .disabled(normalizedNewRuleExtension.isEmpty)
                    }
                }
            } header: {
                Text(L10n.string("settings.openWith.rules.header", "Rules"))
            } footer: {
                Text(L10n.string(
                    "settings.openWith.rules.footer",
                    "Rules take precedence over the default editor; the system association is the fallback."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        // `.fileImporter` has no public `directoryURL`/initial-location
        // parameter, so we can't force `/Applications` as the start
        // directory here. The standard Open panel is used as-is; macOS
        // remembers the last-used directory across launches, so in
        // practice it lands on `/Applications` after the first use.
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.application]
        ) { result in
            defer { activePicker = nil }
            guard case .success(let url) = result, let picker = activePicker else { return }
            switch picker {
            case .defaultEditor:
                store.defaultEditorPath = url.path(percentEncoded: false)
            case .rule(let ext):
                var associations = store.fileAssociations
                associations[ext] = url.path(percentEncoded: false)
                store.fileAssociations = associations
                newRuleExtension = ""
            }
        }
    }

    /// Resolves a stored app path to a user-facing display name, or the
    /// "system default" placeholder when no path is set.
    private func appDisplayName(forPath path: String?) -> String {
        guard let path, !path.isEmpty else {
            return L10n.string("settings.openWith.systemDefault", "System default")
        }
        return FileManager.default.displayName(atPath: path)
    }
}

/// Chooses the application used for external SSH sessions.
private struct TerminalSettingsTab: View {
    @Bindable var store: SettingsStore
    @State private var showCustomAppPicker = false

    var body: some View {
        Form {
            Section {
                Picker(L10n.string("settings.terminal.target", "Open sessions in"),
                       selection: $store.terminalTarget) {
                    Text(L10n.string("settings.terminal.target.terminalApp", "Terminal"))
                        .tag(TerminalTarget.terminalApp)
                    Text(L10n.string("settings.terminal.target.iTerm", "iTerm"))
                        .tag(TerminalTarget.iTerm)
                    Text(L10n.string("settings.terminal.target.custom", "Custom App…"))
                        .tag(TerminalTarget.custom)
                }
                if store.terminalTarget == .custom {
                    HStack {
                        Text(store.customTerminalAppPath.map { FileManager.default.displayName(atPath: $0) }
                             ?? L10n.string("settings.terminal.target.noneChosen", "No app chosen"))
                        Spacer()
                        Button(L10n.string("settings.openWith.choose", "Choose…")) {
                            showCustomAppPicker = true
                        }
                    }
                }
            } footer: {
                Text(L10n.string("settings.terminal.externalOnly.footer",
                                "SSH sessions open in an external application. Configure fonts and colors in that application."))
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showCustomAppPicker, allowedContentTypes: [.applicationBundle]) { result in
            if case .success(let url) = result {
                store.customTerminalAppPath = url.path
            }
        }
    }
}

private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            ForEach(KeyboardShortcutsCatalog.groups) { group in
                Section(L10n.string(group.titleKey, group.titleDefault)) {
                    ForEach(group.rows) { row in
                        HStack {
                            Text(L10n.string(row.labelKey, row.labelDefault))
                            Spacer()
                            Text(row.shortcut)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The "What's new" pane (What's New plan, Task 3): the same changelog
/// Task 2's launch-time sheet shows, browsable at any time rather than only
/// once per version bump. Reads the bundled `CHANGELOG.md` the same way
/// `MacSCPApp.decideWhatsNew(store:)` does (`ChangelogResource.load()` off
/// `Bundle.main`, never `Bundle.module` — see that file's own doc comment),
/// parses it with `ChangelogParser.parse`, and renders every release newest
/// first through `WhatsNewList` — the reusable list `WhatsNewSheet` already
/// factored out for exactly this reuse, so this pane repeats none of that
/// rendering. See `loadReleases()` below for how "newest first" is reached.
///
/// No changelog bundled (`ChangelogResource.load()` returns `nil`, e.g. a
/// `swift run` outside a packaged `.app`) shows the same `whatsNew.none`
/// message `WhatsNewSheet`'s empty branch shows, rather than a blank pane.
private struct WhatsNewSettingsSection: View {
    /// `nil` until the first `.task` runs, so `body` never re-parses on
    /// its own: reading it was a COMPUTED property until fix round 1
    /// (2026-09-04) — `body` reads it twice (`releases.isEmpty`, then
    /// `WhatsNewList(releases:)`), and each read re-ran
    /// `ChangelogResource.load()` + `ChangelogParser.parse(` +
    /// `releases(newerThan:)` over the real ~720-line `CHANGELOG.md`.
    /// `SettingsStore` is `@Observable`, so any tracked mutation while
    /// this pane was visible re-ran `body` and, with it, both parses —
    /// for no reason connected to the changelog itself. Loading once into
    /// `@State` from `.task` decouples the two: the changelog is read and
    /// parsed exactly once per appearance of this pane, never again while
    /// `store` changes underneath it.
    @State private var releases: [ChangelogRelease]?

    var body: some View {
        Group {
            switch releases {
            case nil:
                // Not loaded yet — `.task` below fires once immediately
                // after this first render, so real content follows within
                // the same frame or two; nothing to show in the meantime.
                Color.clear
            case .some(let releases) where releases.isEmpty:
                VStack {
                    Spacer()
                    Text(L10n.string("whatsNew.none", "No changelog shipped with this build."))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(let releases):
                ScrollView {
                    WhatsNewList(releases: releases)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .task {
            guard releases == nil else { return }
            releases = Self.loadReleases()
        }
    }

    /// The actual read-and-parse, kept OUT of `body` on purpose — see
    /// `releases`'s doc comment above. "Newest first" is Task 1's own
    /// public, tested newest-first sort (`releases(newerThan:in:)`'s doc
    /// comment: "sorted newest first ... independent of `releases`'s own
    /// order"), called with `"0"` so every parsed release compares newer
    /// and none is filtered out, only sorted — not a second comparison
    /// against `ChangelogRelease.version` written in this file.
    private static func loadReleases() -> [ChangelogRelease] {
        guard let markdown = ChangelogResource.load() else { return [] }
        return ChangelogParser.releases(newerThan: "0", in: ChangelogParser.parse(markdown))
    }
}

/// The "SSH" protocol section (M18/T7): the external-terminal target picker
/// (moved out of the former "Terminal" tab).
///
/// It used to carry a second, one-button section linking to `SSHKeysSheet`;
/// that link moved to "Manage Data", which gathers all five management
/// overlays in one list. External-terminal target was, for a while, the
/// only setting left here — Task 9 ended that by adding three more
/// sections below it: connect timeout, keep-alive probing, and reconnect
/// behaviour, all four settings (Task 9's connect timeout and reconnect
/// behaviour, plus keep-alive's two settings since 2026-09-02) read
/// straight off `SettingsStore` and bind directly, the same way
/// `autoRefreshEnabled`/`autoRefreshIntervalSeconds` do above.
private struct SSHSettingsSection: View {
    @Bindable var store: SettingsStore
    var body: some View {
        Form {
            // Connect timeout (Task 9): bounds the dial itself, before a
            // session exists to show liveness for at all.
            Section {
                Stepper(
                    value: Binding(
                        get: { store.connectTimeoutSeconds },
                        set: { store.connectTimeoutSeconds = $0 }
                    ),
                    in: 5...120
                ) {
                    Text(String(
                        format: L10n.string(
                            "settings.connection.timeout %lld", "Give up after %lld seconds"),
                        store.connectTimeoutSeconds))
                }
            } header: {
                Text(L10n.string("settings.connection.timeout.header", "Connect Timeout"))
            } footer: {
                // Honest about scope, and deliberately carrying NO
                // multiplier. A tab dial has three stages, not two — TCP
                // connect, a fixed per-hop login window, SFTP version wait
                // — and this setting reaches the first and the third.
                // `SettingsStore.connectTimeoutSeconds` has the
                // measurement and the arithmetic; what matters here is that
                // `2 × value + 10s` is not a ratio a sentence can state,
                // because at the clamp minimum of 5 it is 4× and near the
                // maximum of 120 it is barely 2×. Two earlier drafts of
                // this text each stated a ratio, in opposite directions,
                // and both were wrong; the text now says only what is true
                // at every value the stepper offers.
                Text(L10n.string(
                    "settings.connection.timeout.footer",
                    "Bounds two stages of a connection separately: waiting for the server "
                        + "to answer, and waiting for it to open the file session. The "
                        + "number applies to each of them, and between them sits a fixed "
                        + "waiting period this setting does not cover — so a failing "
                        + "connection takes noticeably longer than the seconds shown. "
                        + "Through a jump host, reaching the server from the jump host is "
                        + "not covered either."))
                    .foregroundStyle(.secondary)
            }

            // Keep-Alive (Task 9; rebound to two settings 2026-09-02):
            // `keepAliveEnabled` and `keepAliveIntervalSeconds` are each
            // their own persisted setting now, so the toggle and stepper
            // bind straight to `store`, the same shape as the auto-refresh
            // toggle/stepper above.
            Section {
                Toggle(
                    L10n.string(
                        "settings.connection.keepAlive", "Check the connection while idle"),
                    isOn: $store.keepAliveEnabled)
                Stepper(
                    value: Binding(
                        get: { store.keepAliveIntervalSeconds },
                        set: { store.keepAliveIntervalSeconds = $0 }
                    ),
                    in: 15...600
                ) {
                    Text(String(
                        format: L10n.string(
                            "settings.connection.keepAliveInterval %lld", "Every %lld seconds"),
                        store.keepAliveIntervalSeconds))
                }
                .disabled(!store.keepAliveEnabled)
            } header: {
                Text(L10n.string("settings.connection.keepAlive.header", "Keep-Alive"))
            } footer: {
                // Turning the toggle off no longer touches the interval at
                // all (2026-09-02: two settings, not one sentinel) — the
                // stepper's own value just sits there, disabled, until the
                // toggle is switched back on. No "remembered while off,
                // lost on relaunch" hedge to write here any more: there is
                // nothing transient to describe.
                Text(String(
                    format: L10n.string(
                        "settings.connection.keepAlive.footer %lld",
                        "While on, MacSCP checks an idle connection every %lld seconds. Off "
                            + "keeps the interval for when you turn it back on."),
                    store.keepAliveIntervalSeconds))
                    .foregroundStyle(.secondary)
                Text(L10n.string("settings.connection.tlsKeepAlive",
                    "TLS connections always send a read-only SFTP keep-alive every 10 seconds, including through a TLS jump host."))
                    .foregroundStyle(.secondary)
            }

            // Reconnect behaviour (Task 9): what happens once a connection
            // is found gone.
            Section {
                Picker(
                    L10n.string("settings.connection.reconnect", "When a connection is lost"),
                    selection: $store.reconnectBehaviour
                ) {
                    Text(L10n.string("settings.connection.reconnect.offerOnly", "Offer to reconnect"))
                        .tag(ReconnectBehaviour.offerOnly)
                    Text(L10n.string(
                        "settings.connection.reconnect.onceThenAsk", "Reconnect once, then ask"))
                        .tag(ReconnectBehaviour.onceThenAsk)
                    Text(L10n.string(
                        "settings.connection.reconnect.automatic", "Reconnect automatically"))
                        .tag(ReconnectBehaviour.automatic)
                }
            } header: {
                Text(L10n.string("settings.connection.reconnect.header", "Reconnect"))
            } footer: {
                // The host-key sentence holds regardless of which option is
                // picked (architecture invariant: a key mismatch is a hard
                // stop, never auto-accepted) — stated here so "automatic"
                // does not read as "no confirmation ever".
                Text(L10n.string(
                    "settings.connection.reconnect.footer",
                    "\u{201C}Offer to reconnect\u{201D} waits for a click. "
                        + "\u{201C}Reconnect once, then ask\u{201D} retries automatically one "
                        + "time, then falls back to asking. \u{201C}Reconnect "
                        + "automatically\u{201D} keeps retrying on its own. A changed host key "
                        + "always stops and asks, no matter which option is selected."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// The "Manage Data" section: one list of shortcuts to the five management
/// overlays, which were previously split between the Sessions menu (all
/// five) and the "SSH" section (keys only). The Sessions menu keeps every
/// entry it had, ⇧⌘K/⇧⌘L included — this is a second door, not a
/// replacement.
///
/// Two of the five open HERE, as sheets on the Settings window, the way
/// `SSHKeysSheet` already did from the "SSH" section. `KnownHostsSheet`
/// builds its own `KnownHostsStore` over a fixed directory — a stateless
/// read-modify-write struct addressed by `(host, port)`, rebuilt on every
/// connect — and the main window shows nothing derived from it, so a copy
/// here cannot leave the other window stale. `SSHKeysSheet` is presented
/// here because it always has been (this section only inherited it from the
/// "SSH" section); note that the connection form's key picker
/// (`ManagedKeysLoad.connectableKeys()`) IS derived state, so
/// deleting a key here can leave an open form holding a dead
/// `managedKeyID` — pre-existing behaviour, unchanged by this section.
///
/// The other three — logins, server certificates and hidden imports — are
/// NOT presented here; they route through `TabCommands` to the main window's
/// own presentation of the same sheet, which keeps the existing view model
/// and refresh wiring intact. Logins and hidden imports edit state the main
/// window's sidebar is a live view of, and a sheet in THIS window is modal
/// only to THIS window, so the main window would stay clickable next to a
/// stale sidebar. Server certificates are routed for the trust decision
/// rather than the data. See `ContentView.presentLoginSetsFromSettings()`
/// and `presentServerCertificatesFromSettings()` for the full reasoning.
///
/// Those three are `.disabled` while no main window EXISTS
/// (`TabCommands.hasMainWindow`): they have nowhere to go then, and a row
/// that swallows a click is worse here than in the Sessions menu, where the
/// user is at least standing in a window. A minimized window or a hidden app
/// leaves them enabled on purpose — the handlers raise the window before
/// presenting, so the action works from either state.
///
/// The per-session audit log is deliberately absent: `AuditLogSheet` takes a
/// `StoredSession` and is opened from that session's sidebar row. There is no
/// all-sessions audit view for a global list to link to, and inventing a
/// session picker here would be a new feature, not a shortcut.
private struct ManageDataSettingsSection: View {
    var settingsBridge: SettingsWindowBridge
    /// The two overlays this window presents itself — same `@State` flag +
    /// `.sheet(isPresented:)` pattern the "SSH" section used for keys before
    /// this section existed.
    @State private var showSSHKeysSheet = false
    @State private var showKnownHostsSheet = false

    var body: some View {
        Form {
            Section {
                Button {
                    showSSHKeysSheet = true
                } label: {
                    Label(L10n.string("menu.sshKeys", "SSH Keys…"), systemImage: "key")
                }
                Button {
                    settingsBridge.showLoginsFromSettings?()
                } label: {
                    Label(
                        L10n.string("menu.logins", "Logins…"),
                        systemImage: "person.badge.key")
                }
                .disabled(!settingsBridge.hasMainWindow)
                Button {
                    showKnownHostsSheet = true
                } label: {
                    Label(
                        L10n.string("menu.knownHosts", "Known Hosts…"),
                        systemImage: "lock.shield")
                }
                Button {
                    settingsBridge.showServerCertificatesFromSettings?()
                } label: {
                    Label(
                        L10n.string("menu.serverCertificates", "Server Certificates…"),
                        systemImage: "checkmark.seal")
                }
                .disabled(!settingsBridge.hasMainWindow)
            } footer: {
                // Two lines, the second only when it applies: where the
                // routed entries land, said BEFORE the window changes under
                // the user, and — when they are greyed out — why. A disabled
                // row shows no tooltip, so this footer is the only place that
                // explanation can live.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(
                        "settings.manageData.footer",
                        "Logins, server certificates and hidden imports open in the main "
                            + "window, where the state they change belongs."))
                    if !settingsBridge.hasMainWindow {
                        Text(L10n.string(
                            "settings.manageData.needsMainWindow",
                            "They are unavailable while no main window is open."))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showSSHKeysSheet) {
            SSHKeysSheet()
        }
        .sheet(isPresented: $showKnownHostsSheet) {
            KnownHostsSheet(store: KnownHostsStore(directory: SessionStore.defaultDirectory))
        }
    }
}

/// The "S3" protocol section (M18/T7): the default presigned-link expiry
/// (moved out of the former "Transfers" tab) — home for future S3-specific
/// settings.
private struct S3SettingsSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            // S3 share links (M14/T5): the default expiry `PresignedURLSheet`
            // pre-fills when generating a presigned GET/PUT link — the sheet
            // itself lets a link override this per generation.
            Section {
                Picker(
                    L10n.string("settings.transfers.presignedExpiry", "Default share-link expiry"),
                    selection: $store.presignedDefaultExpiry
                ) {
                    Text(L10n.string("presigned.expiry.15min", "15 Minutes")).tag(PresignedExpiry.fifteenMinutes)
                    Text(L10n.string("presigned.expiry.1h", "1 Hour")).tag(PresignedExpiry.oneHour)
                    Text(L10n.string("presigned.expiry.1d", "1 Day")).tag(PresignedExpiry.oneDay)
                    Text(L10n.string("presigned.expiry.7d", "7 Days")).tag(PresignedExpiry.sevenDays)
                }
            } header: {
                Text(L10n.string("settings.transfers.presignedExpiry.header", "S3 Share Links"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
