import AppKit
import SwiftUI
import macSCPCore

/// The continuation bridge this sheet is presented through
/// (`ConflictPromptBridge`, with `ConflictPromptItem`) lives in Core, next to
/// the queue that drives it — it is pure state machine, and the app target
/// has no tests to hold its resumption rules honest. See
/// `Sources/macSCPCore/Presentation/ConflictPromptBridge.swift`; the
/// presentation contract it must be presented under is
/// `transferConflictSheet(bridge:)`, right below the sheet itself.

/// Conflict sheet content. Its own view type because of the local toggle
/// state (`applyToAll`) — SwiftUI instantiates it fresh for every sheet
/// presentation.
private struct ConflictSheetView: View {
    let conflict: TransferConflict
    let onResolve: (ConflictResolution, Bool) -> Void
    let onCancel: () -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("conflict.title", "File already exists"))
                .font(.headline)
            Text(String(format: L10n.string(
                "conflict.message", "“%@” already exists in “%@”."),
                conflict.fileName, conflict.destinationDirectory))
                .foregroundStyle(.secondary)
            if conflict.isPartOfFolderTransfer {
                Text(L10n.string(
                    "conflict.folderHint",
                    "Canceling stops the whole folder transfer; files already copied are kept."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L10n.string("conflict.applyToAll", "Apply to all further items"), isOn: $applyToAll)
            HStack {
                Spacer()
                Button(conflict.isPartOfFolderTransfer
                    ? L10n.string("conflict.cancelFolder", "Cancel folder transfer")
                    : L10n.string("common.cancel", "Cancel"),
                    role: .cancel) { onCancel() }
                Button(L10n.string("conflict.rename", "Rename")) { onResolve(.rename, applyToAll) }
                Button(L10n.string("conflict.skip", "Skip")) { onResolve(.skip, applyToAll) }
                Button(L10n.string("conflict.overwrite", "Overwrite"), role: .destructive) {
                    onResolve(.overwrite, applyToAll)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Escape/click-outside must NOT resolve the prompt without fulfilling
        // the continuation — that would leave `cancelAll`/the queue hanging.
        // Resolution happens exclusively through the buttons.
        .interactiveDismissDisabled(true)
    }
}

extension View {
    /// The ONE way the conflict sheet is presented, so the contract below
    /// cannot drift or be reinvented next to it.
    ///
    /// Three deliberate choices, each of which the bridge's exactly-once
    /// argument depends on (see `ConflictPromptBridge` in Core):
    ///
    /// 1. **The binding's setter is inert.** SwiftUI writes `nil` to it when it
    ///    decides the sheet should go away — but that write says nothing about
    ///    WHICH prompt it refers to, and by the time it lands the queue may
    ///    already be asking about the next file (one remote `stat` between two
    ///    conflicts, against a ~250 ms dismissal animation). Answering
    ///    "whatever is current" there returned `nil` — cancel — for a conflict
    ///    the user had not been asked about yet, and a cancelled item takes its
    ///    whole group with it: the folder transfer died after the user pressed
    ///    "Skip". The getter alone drives presentation, and `resolve` clearing
    ///    `currentPrompt` is what dismisses the sheet.
    /// 2. **The safety net names its prompt.** `onDisappear` fires on the
    ///    content view being torn down, which is the only hook that still has
    ///    `item` — so the net can say "the sheet for THIS prompt went away" and
    ///    `dismiss(promptID:)` can ignore it unless that prompt is still the
    ///    open, unanswered one. There is no `onDismiss:` here for exactly that
    ///    reason: it carries no item, so it structurally cannot name one.
    /// 3. **Every button routes into the bridge NAMING ITS OWN PROMPT**, and
    ///    the sheet itself is `.interactiveDismissDisabled(true)`, so
    ///    Escape/click-outside cannot strand a continuation for the net to have
    ///    to catch. The buttons pass `item.id` for the same reason the net
    ///    does: a tap delivered twice (double click, or a repeated press of
    ///    `Overwrite`'s `.defaultAction` shortcut) while this sheet animates
    ///    out would otherwise answer the NEXT conflict — the queue has already
    ///    asked it.
    func transferConflictSheet(bridge: ConflictPromptBridge) -> some View {
        sheet(item: Binding(
            get: { bridge.currentPrompt },
            set: { _ in /* see 1. above — deliberately inert */ })
        ) { item in
            ConflictSheetView(
                conflict: item.conflict,
                onResolve: { resolution, applyToAll in
                    bridge.resolve(
                        promptID: item.id, (resolution: resolution, applyToAll: applyToAll))
                },
                onCancel: { bridge.dismiss(promptID: item.id) }
            )
            .onDisappear { bridge.dismiss(promptID: item.id) }
        }
    }
}

/// Mediates access to the enclosing `NSWindow` — SwiftUI offers no API of
/// its own for this. `view.window` is only set AFTER the `NSView` has been
/// hooked into the window hierarchy, hence the `DispatchQueue.main.async`
/// detour (M5c/T0).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// The file a `.sheet(item:)` presents `ImportKeySheet` over (PEM private
/// keys plan, Task 4) — a fresh identity per presentation, so pressing
/// "Convert key…" twice for the same path opens the sheet twice rather than
/// being swallowed as "the same item".
///
/// A type of its own rather than the `URL` itself, for the reason
/// `SSHKeysSheet`'s own `ImportTarget` is one: `URL` is not `Identifiable`,
/// and identifying a presentation by its path would tie the sheet's life to
/// the file it happens to name.
///
/// It carries the TAB as well as the file (fix round 1, review finding C1),
/// both taken when "Convert key…" was pressed. A `.sheet(item:)` closure
/// runs when the sheet CLOSES, and ⌘1-9 switches tabs while one is open —
/// nothing gates that. Resolving the tab there re-pointed and re-dialled
/// whichever tab happened to be active by then, writing a key path into
/// another session's stored record while the tab that actually failed was
/// left on the PEM file. Same "capture now, not later" discipline
/// `PresignedSheetItem` and `closeRequest` already follow.
struct ImportKeyTarget: Identifiable {
    let id = UUID()
    let fileURL: URL
    /// The tab whose failed attempt this conversion is for — a reference,
    /// so the conversion still reaches it after it has been dragged to
    /// another window (the tab moves, its identity does not).
    ///
    /// Residue, not a feature: holding the reference does not make the
    /// dismissal legal from here. The captured tab can be CLOSED or dragged
    /// to another window while the sheet is open, and the closure then runs
    /// `convertedKeyImported(_:for:)` — and through it `retryConnect(_:)` —
    /// from THIS window on a tab this window may no longer own. Nothing
    /// re-checks ownership against `TabRegistry` at dismissal, and nothing
    /// closes the sheet when the tab goes.
    let tab: SessionTab
}

struct ContentView: View {
    /// Passed in from `MacSCPApp` (same instance as the `Settings` scene —
    /// no singleton, per the v2 multi-window rule). Wired into every tab's
    /// queue at tab creation and kept in sync via `.onChange` (M5c/T4 queue
    /// parallelism, M5c/T5 bandwidth limits).
    let settingsStore: SettingsStore
    /// Posts the macOS notifications for a lost connection and a failed
    /// transfer (next build of 2026-09-17, Task 7). `MacSCPApp` hands in the
    /// live one; built without one, a window is silent
    /// (`ErrorNotifier.silent()`, fix round 1). It holds no state of this
    /// window.
    let errorNotifier: ErrorNotifier
    /// App-global bandwidth ceilings (M8a/T2), created once in `MacSCPApp`.
    /// Every tab's queue resolves its throttle from this one instance, so
    /// limits apply in aggregate across tabs (M8a/T3).
    let bandwidthLimiter: BandwidthLimiter
    /// App-wide per-session audit log store (M9b), created once in
    /// `MacSCPApp` (no singleton) — shared by `sessionListViewModel` (log
    /// cleanup on delete) and every stored-session tab's `AuditRecorder`
    /// (see `attachAuditRecorder`).
    let auditStore: AuditLogStore
    /// THIS window's menu bridge (M8a/T4), published as a focused scene
    /// value in `windowChrome(_:)` and read back by `MacSCPCommands`
    /// through `@FocusedValue` — so the menus act on the window in front
    /// without any closure having to ask whether it is that window
    /// (Detachable Tabs plan, Task 2 fix round 1). One instance per window:
    /// `@State`, so it survives every re-init of this struct.
    ///
    /// A caller may inject one (tests do); production passes nothing and
    /// gets the window's own.
    @State var tabCommands: TabCommands
    /// The Settings window's route into a main window — app-wide, and the
    /// one bridge that could not become per window. See
    /// `SettingsWindowBridge`.
    let settingsBridge: SettingsWindowBridge
    /// Menu-bar status bridge (M11n), created once in `MacSCPApp` (no
    /// singleton, same pattern as the stores above) and shared with the
    /// AppKit `MenuBarController` there. This view mirrors `tabsModel.tabs`
    /// into it — once in `publishToMenuBarIfKey()`, run from
    /// `performWindowSetup()`, and again whenever the `.onChange(of: tabIDs)`
    /// in the same file's modifier chain fires — and sets its window-raising
    /// closures in `publishToMenuBarIfKey()` alone (both in
    /// `ContentView+Lifecycle.swift`); see `MenuBarStatusModel`'s doc
    /// comment.
    let menuBarModel: MenuBarStatusModel
    /// Assigned in `init` (not a bare default value) so it can pass
    /// `auditStore` through — mirrors `_tabsModel` below.
    @State var sessionListViewModel: SessionListViewModel
    /// The Keychain-backed secret store every window-level path that asks
    /// about a managed key's passphrase reads (connection-liveness plan,
    /// Task 6 fix round 3, review item "Important — the seam is only half
    /// there"). A `let`, not constructed inline at each call site — those
    /// call sites used to build their own `KeychainSecretStore()` on the
    /// spot, unreachable by any test seam; routing them through this one
    /// property is what lets `ContentView.init`'s `secretStore:` parameter
    /// isolate them the same way `sessionListViewModel:` isolates
    /// `startSession`'s OWN keychain write.
    ///
    /// Deliberately no list of those call sites here. This comment used to
    /// name two, and the set has grown twice since without the comment
    /// moving (fix round 2, PEM private keys plan Task 4) — a count in a
    /// comment is a claim about the rest of the project, and this one is
    /// better made by `grep` than by prose (CLAUDE.md, "Comments that
    /// describe other code").
    let secretStore: any SecretStore
    /// The managed-key store those same paths read alongside `secretStore`
    /// above — same reasoning, same fix.
    let managedKeyStore: ManagedKeyStore
    /// Where the sidebar start's tab rule gets a FRESH tab from
    /// (jump-and-groups plan, Task 1) — `nil` in production, which means
    /// the window's own `makeTab()` with the real connector; see
    /// `makeSidebarTab()`.
    ///
    /// A test seam, and only that: `init`'s `sidebarTabFactory:` defaults
    /// to `nil`, and the window's one production construction in
    /// `MacSCPApp` passes nothing (`DetailSurfaceWiringGuardTests` checks
    /// that it keeps passing nothing). It exists so `JumpTwoTabsTests` can
    /// drive the real `connectFromSidebar` → `startWithoutAsking` path with
    /// tabs whose connectors it controls, instead of re-spelling the tab
    /// rule beside it. A plain `let`, for the reason `secretStore` above is
    /// one: a test cannot reassign a property after construction and have
    /// it take.
    let sidebarTabFactory: (@MainActor () -> SessionTab)?
    /// Window-scoped tab collection (M8a/T3). Everything that used to be
    /// window-wide session state (connection form, session, queue, conflict
    /// bridge, title, edit error, reconnect flag) now lives per tab in
    /// `SessionTab`; what stays declared on the window itself is session
    /// state that used to be per window, not per tab.
    @State var tabsModel: TabsViewModel<SessionTab>
    @State var importedHosts: [SSHConfigHost] = []
    /// The full, unfiltered `~/.ssh/config` parse (M11f/T2) — read from disk
    /// exactly once in `performWindowSetup()`, run from the `.task` in
    /// `ContentView+Detail.swift`. `refreshImportedHosts()` re-derives
    /// `importedHosts`/`hiddenImportAliases` from THIS, never by re-reading
    /// the config file, so hiding/unhiding an entry can never race a
    /// concurrent edit of the file the user made in a text editor.
    @State var fullImportedHosts: [SSHConfigHost] = []
    /// Aliases currently hidden from the IMPORTED sidebar section (M11f/T2),
    /// freshly read from `HiddenImportStore` by every `refreshImportedHosts()`
    /// call. Its count drives the Sessions-menu/background-menu "Hidden
    /// Imports…" title (see `tabCommands.hiddenImportsCount` below).
    @State var hiddenImportAliases: [String] = []
    /// Red inline message after `HiddenImportStore.hide`/`allHidden` throws
    /// (M11f/T2 review, findings 1+2) — same pattern as
    /// `SessionSidebar.jumpRestoreErrorMessage`. Both `hideImported` and
    /// `refreshImportedHosts` write here so a store failure is reported
    /// instead of silently leaving the row in place (hide) or failing open
    /// (refresh); cleared on the next successful `refreshImportedHosts`.
    @State var hiddenImportsErrorMessage: String?
    /// Handed over by `WindowAccessor` — basis for the active resize calls
    /// on state transitions (M5c/T0).
    @State var window: NSWindow?
    /// "Keep on Top" (Detachable Tabs plan, Task 4): per window, not
    /// persisted — Task 5's restoration seed is where a sticky flag would
    /// travel across launches, and this task adds nothing there. Applied
    /// to `window` through `WindowLevelPlan.level(keepOnTop:)` in
    /// `windowChrome(_:)`'s `.onChange` and in the `WindowAccessor` closure
    /// itself, and mirrored onto `tabCommands.keepOnTop` the same way
    /// `isActiveTabConnected` mirrors below — see `body`'s `.onChange(of:
    /// keepOnTop, …)`.
    @State var keepOnTop = false
    /// What this window was opened with (Detachable Tabs plan, Task 2):
    /// `nil` for the PRIMARY window — the one SwiftUI opens for the
    /// value-keyed `WindowGroup` with no value at launch — and a real seed
    /// for a window opened by `openWindow(value:)` when a tab was moved out
    /// of another one. `claimSeededTabs()` is what consumes it, once, on
    /// this window's setup pass.
    ///
    /// A RESTORED window is opened with a seed too, and the same setup
    /// pass consumes it — but through the other half of the type: it
    /// carries described tabs rather than live ids, so the claim comes
    /// back empty and `restoreDescribedWindow()` builds the tabs instead.
    /// See `WindowSeed` for the two halves.
    let seed: WindowSeed?
    /// What this LAUNCH still has to restore (Detachable Tabs plan,
    /// Task 5) — `nil` in a `ContentView` built outside the app (every
    /// test that constructs one), which restores nothing.
    ///
    /// Both halves are handed over exactly once: the primary window takes
    /// its own description here, and it is also the window that opens the
    /// others, because `openWindow(value:)` needs an environment value
    /// `MacSCPApp.init` does not have.
    let restorationLaunch: WindowRestorationLaunch?
    /// This window's identity in `TabRegistry` (Detachable Tabs plan, Task
    /// 2). `@State`, so it is created once per window and survives every
    /// re-init of this struct — a fresh `WindowID` per body evaluation would
    /// make the registry believe a new window had opened on every repaint.
    @State var windowID = WindowID()
    /// Opens a second window for a moved tab — see `moveToNewWindow(_:)`.
    /// Not `private`: the move itself lives in `ContentView+Lifecycle.swift`.
    @Environment(\.openWindow) var openWindow
    /// Whether THIS window is the key one — the per-window signal the
    /// menu-bar bridge is gated on (see `publishToMenuBarIfKey()`). An
    /// environment value rather than a `didBecomeKey` observer: it needs no
    /// subscription and no polling, and `.onChange(…, initial: true)` sees
    /// every transition in both directions.
    @Environment(\.controlActiveState) var controlActiveState
    /// Last browser window size, remembered on disconnect — the next
    /// connect grows to it instead of the minimum size, if it's larger.
    /// In memory, for this run only; the primary window also persists it
    /// (`SettingsStore.mainWindowBrowserSize`) and prefers that — see
    /// `MainWindowSizePlan.rememberedBrowserSize`.
    @State var lastBrowserSize: CGSize?
    /// Whether the primary window's frame autosave is suspended: set by the
    /// shrink to the form size, cleared by the next connect's grow, so the
    /// form size is never what AppKit keeps as the window's frame. Always
    /// `false` in a window opened by a move, which has no autosave name.
    /// See `MainWindowSizePlan`.
    @State var frameAutosaveSuspended = false
    /// The width the session sidebar comes up at, read from `SettingsStore`
    /// once, when the window is built.
    ///
    /// Updated only while the sidebar is absent, so restoring the divider
    /// does not feed layout measurements back into an active drag.
    @State var sidebarOpeningWidth: CGFloat
    @State var isSidebarVisible = true
    @State var showsTunnelWorkspace = false
    @State var showsSettingsWorkspace = false
    @State var settingsSection: SettingsSection? = .general
    @State var settingsPageBridge = SettingsWindowBridge()
    let launchLanguage: AppLanguage
    @State var tunnelWorkspaceSelection: TunnelWorkspaceSelection = .all
    @State var requestsNewTunnel = false
    /// Tab pending a destructive close confirmation (active transfers) — nil
    /// when no confirmation is showing (M8a/T4).
    @State var closeRequest: SessionTab?
    /// Warning text for `closeRequest`, frozen at the moment the dialog is
    /// requested (M8b review, finding 4). The dialog's `message:` builder
    /// re-evaluates on every render; recomputing `TabCloseWarning.message`
    /// there instead of reading this snapshot would let the text go blank
    /// mid-dialog if the underlying transfers finish while it's still open —
    /// blank text under a destructive "Close" button.
    @State var closeWarningText: String = ""
    /// The tab whose SIBLINGS a pending "Close Other Tabs" would close —
    /// nil when no such confirmation is showing. The tab held here is the
    /// one that SURVIVES, which is also the one the menu was opened on.
    @State var closeOthersRequest: SessionTab?
    /// Warning text for `closeOthersRequest`, frozen for the same reason
    /// `closeWarningText` is: the dialog reads a snapshot rather than
    /// recomputing counts that can change while it is on screen.
    @State var closeOthersWarningText: String = ""
    /// The toolbar's pending Upload/Download question (maintainer decision
    /// of 2026-09-16), or `nil` when none is showing — set by
    /// `requestToolbarTransfer` for a selection of more than one item or a
    /// folder, answered in `ContentView+Sheets.swift`.
    @State var toolbarTransferRequest: ToolbarTransferRequest?

    // MARK: - Session already open ("Sitzung ist schon offen", C2)

    /// Everything the "already open" query needs, captured when the query
    /// is raised: what was asked for, where the existing session is, and
    /// how the row wanted it shown.
    struct AlreadyOpenSessionRequest: Identifiable {
        let id = UUID()
        /// What the sidebar row asked to start.
        let stored: StoredSession
        /// The tab "Go to Existing Tab" activates. An id rather than the
        /// tab itself: the tab can be closed while the query is up, and
        /// `TabsViewModel.activate(_:)` answers an id naming no tab by
        /// leaving the active tab alone.
        let existingTabID: UUID

    }

    /// A sidebar start that stopped because some tab already holds the
    /// stored session it named — drives the query in
    /// `ContentView+Sheets.swift`, and is `nil` whenever none is showing.
    ///
    /// No frozen message text beside it, unlike `closeRequest` and its
    /// `closeWarningText`: that pair exists because `TabCloseWarning
    /// .message` is recomputed from transfers that keep finishing while the
    /// dialog is up, so the text could go blank mid-dialog. What this query
    /// says is the session's NAME, and the request already carries the
    /// `StoredSession` itself — a value, taken when the query was raised
    /// and unable to change afterwards.
    @State var alreadyOpenRequest: AlreadyOpenSessionRequest?

    // MARK: - Audit log (M9b/T3)

    /// Session whose audit log sheet is open, or `nil` when none is —
    /// `StoredSession` drives `.sheet(item:)` directly (it's already
    /// `Identifiable`). Opened from the sidebar's "Audit Log…" entry, works
    /// whether or not that session is currently connected.
    @State var auditLogSession: StoredSession?

    // MARK: - Key conversion (PEM private keys plan, Task 4)

    /// The PEM key file the failed-connect surface's "Convert key…" is
    /// converting, or `nil` when that sheet is closed — the same
    /// `.sheet(item:)` shape `auditLogSession` uses, opened from
    /// `convertFailedKey(_:)` and presented in `ContentView+Sheets.swift`.
    ///
    /// Carries the file URL AND the tab as values, both taken when the
    /// button was pressed, so neither a form the user keeps typing into
    /// behind the sheet nor a ⌘1-9 tab switch can change what the
    /// conversion is applied to (see `ImportKeyTarget`).
    @State var convertKeyTarget: ImportKeyTarget?

    /// The login-set question a finished conversion asks (maintainer
    /// decisions of 2026-09-16, Task 2), or `nil` when there is none — set by
    /// `convertedKeyImported(_:for:)` for a session bound to an SSH
    /// private-key set, answered by `repointLoginSet(_:)` or
    /// `convertForThisAttemptOnly(_:keyPath:)`.
    @State var setRepointRequest: LoginSetRepointRequest?

    /// Whether the conversion sheet has CLOSED since `setRepointRequest` was
    /// set — the dialog's presentation reads both. The import sheet calls its
    /// completion before it dismisses itself, so the request exists while the
    /// sheet is still up, and a presentation raised then does not appear (the
    /// import-password sheet's `onDismiss:` in `ContentView+Sheets.swift`
    /// records the same limit for the conflict sheet, M19/T8). Armed in the
    /// conversion sheet's `onDismiss:`, disarmed when the dialog closes.
    @State var setRepointDialogArmed = false

    // MARK: - Port forwarding (port-forwarding plan, Task 6)

    /// Session whose forwarding-profile sheet is open, or `nil` — the same
    /// `.sheet(item:)` shape `auditLogSession` uses, opened from the row's
    /// "Port forwarding ▸ Manage forwardings…" entry. Opening it dials
    /// nothing.
    @State var tunnelProfilesSession: StoredSession?

    /// This WINDOW's answer to an unknown host key on a forwarding's own
    /// dial. A tunnel has no tab, so it has no `ConnectionViewModel` to
    /// carry the question; this bridge and the sheet it drives are where it
    /// is asked. Autostart never reaches it — `TunnelManager
    /// .startAutoStart(_:)` hands `.refusing`.
    @State var tunnelHostKeyBridge = TunnelHostKeyPromptBridge()

    /// The decider handed to every forwarding this window starts. A MISMATCH
    /// never arrives here: it is a hard stop inside the dial, decided before
    /// any decider is consulted.
    var tunnelHostKeyDecider: HostKeyDecider {
        let bridge = tunnelHostKeyBridge
        return .asking { candidate in await bridge.ask(candidate) }
    }

    // MARK: - Connection diagnostics

    /// This window's diagnostics panel — open or not — and the one place its
    /// run is stopped.
    ///
    /// Filled by `showDiagnostics(for:)` alone, the window's single entry that
    /// every door goes through, from a `DiagnosticsTarget`: a VALUE taken at
    /// the moment the user asked, so a tab that reconnects or a row that is
    /// renamed cannot change what the open panel is diagnosing. Presenting it
    /// measures nothing; the diagnosis starts on the panel's own button
    /// (decision of 2026-09-02), and ends with the sheet or the tab.
    ///
    /// An object rather than an optional value: `endDiagnostics()` has to
    /// cancel as well as forget — see `DiagnosticsPresenter`.
    @State var diagnostics = DiagnosticsPresenter()

    // MARK: - Known hosts (M10a/T2)

    /// Drives the known-hosts management sheet — opened from the Sessions
    /// menu (⌘⇧K) and the sidebar's background context menu. No item payload
    /// needed (unlike `auditLogSession`): the sheet always shows the same,
    /// window-wide store.
    @State var showKnownHostsSheet = false

    // MARK: - Server certificates

    /// Drives the server-certificate management sheet — opened from the
    /// Sessions menu, and from Settings' "Manage Data"
    /// (`presentServerCertificatesFromSettings`). Same no-item-payload shape
    /// as `showKnownHostsSheet` above; the certificate list used to be a
    /// second section inside that sheet and is now its own overlay (see
    /// `ServerCertificatesSheet`).
    @State var showServerCertificatesSheet = false

    // MARK: - Login sets (M10b/T3)

    /// Drives the login-sets management sheet — opened from the Sessions
    /// menu (⌘⇧L), the sidebar's background context menu, and Settings'
    /// "Manage Data" (`presentLoginSetsFromSettings`). Same no-item-payload
    /// shape as `showKnownHostsSheet` above (always the same window-wide
    /// `sessionListViewModel`).
    @State var showLoginSetsSheet = false
    /// Internal bridge for opening the login manager's own import picker.
    /// The unified import panel instead passes detectedLoginImportData.
    @State var loginSetsSheetStartsImport = false

    // MARK: - Session overview (session overview plan, Task 2)

    /// The stored session the sidebar is pointing at, as reported by
    /// `SessionSidebar.onSelectSession`.
    ///
    /// An id and not a `StoredSession`, so the overview always describes the
    /// record as it stands: it is resolved against the live list on every
    /// render (`overviewSession`), which is also what makes a deleted session
    /// disappear from the detail pane without a second rule to clear this.
    ///
    /// Window-scoped rather than per-tab, matching where the sidebar is: one
    /// sidebar, one selection, and switching tabs does not move the pointer.
    @State var overviewSessionID: UUID?

    /// The session `overviewSessionID` names, or `nil` — no selection, or a
    /// selection whose session is gone.
    var overviewSession: StoredSession? {
        guard let overviewSessionID else { return nil }
        return sessionListViewModel.sessions.first { $0.id == overviewSessionID }
    }

    /// What the DETAIL pane's overview branch shows for `tab`: the session
    /// that tab was restored pointing at, if it still is, and otherwise the
    /// one the sidebar is pointing at (Detachable Tabs plan, Task 5 fix
    /// round 1).
    ///
    /// The per-tab answer comes first because a restored window has N tabs
    /// that were each pointed at a different session, and
    /// `overviewSessionID` — matching where the sidebar is — can only name
    /// one. A tab with no restored pointer, which is every tab made any
    /// other way, gets exactly what it got before this existed.
    ///
    /// Resolved against the live list here, like `overviewSession` above,
    /// so a restored pointer at a session that has since been deleted
    /// falls through to nothing rather than to a stale copy.
    func overviewSession(for tab: SessionTab) -> StoredSession? {
        guard let restored = tab.restoredSessionID else { return overviewSession }
        return sessionListViewModel.sessions.first { $0.id == restored } ?? overviewSession
    }

    /// The group and login-set NAMES behind the two ids a session carries,
    /// read off the window's own lists.
    ///
    /// One line, and it exists so the resolution is asked once per render
    /// rather than once per name: the detail pane needs both halves, and
    /// calling `SessionOverviewNames.resolve` twice would walk both lists
    /// twice to build the same pair.
    func overviewNames(for session: StoredSession) -> (group: String?, loginSet: String?) {
        SessionOverviewNames.resolve(
            for: session, groups: sessionListViewModel.groups,
            loginSets: sessionListViewModel.loginSets)
    }

    // MARK: - Hidden imports (M11f/T2)

    /// Drives the hidden-imports management sheet — opened from the
    /// sidebar's background context menu and Settings' "Manage Data"
    /// (`presentHiddenImportsFromSettings`). Same
    /// no-item-payload shape as `showKnownHostsSheet`/`showLoginSetsSheet`
    /// above: the sheet always reflects `fullImportedHosts` plus a fresh
    /// `HiddenImportStore` read of its own.
    @State var showHiddenImportsSheet = false

    // MARK: - SSH keys (M18/T5)

    /// Drives the SSH-key management sheet — opened from the Sessions menu.
    /// Same no-item-payload shape as `showKnownHostsSheet`/
    /// `showLoginSetsSheet`/`showHiddenImportsSheet` above: `SSHKeysSheet`
    /// always reflects the same window-wide `ManagedKeyStore` directory.
    @State var showSSHKeysSheet = false

    // MARK: - Session export/import (M9a/T3)

    /// Wraps `ExportScope` so it can drive `.sheet(item:)` — `ExportScope`
    /// itself has no stable identity of its own that covers all three cases
    /// (`.all` has none at all).
    struct ExportSheetItem: Identifiable {
        let id = UUID()
        let scope: SessionListViewModel.ExportScope
    }

    @State var exportSheetItem: ExportSheetItem?

    /// A decoded session-import payload plus whether the file it came from was
    /// itself encrypted (which the result alert's plaintext notice needs).
    struct PendingSessionImport {
        let payload: SessionExportPayload
        let wasEncrypted: Bool
    }

    // MARK: - Share link (M14/T5)

    /// Wraps the single selected remote file's S3 key plus the presigned
    /// provider captured at presentation time — the same "capture now,
    /// not later" discipline `detail`'s `bridge`/`tab` locals already use for
    /// the conflict sheet, so the sheet keeps talking to the file system it
    /// was opened against even if the active tab changes underneath it.
    struct PresignedSheetItem: Identifiable {
        let id = UUID()
        /// The object key (no leading slash) `PresignedURLSheet` pre-fills
        /// for both GET (read-only) and PUT (editable) — see
        /// `RemotePath.normalizedAbsolute` at the call site for how a
        /// `RemoteFileItem.path` becomes this.
        let itemKey: String
        let provider: any PresignedURLProvider
    }

    @State var presignedSheetItem: PresignedSheetItem?
    /// Set by `performExport` right before `showExportFileExporter`, and
    /// cleared by the `fileExporter` completion handler — which decides
    /// whether the "exported without password" alert is needed (spec M9a
    /// §3.3) from `exportMissingPasswordCount`, not from this property.
    @State var exportDocument: SessionExportDocument?
    @State var showExportFileExporter = false
    @State var exportMissingPasswordCount = 0
    @State var showExportMissingPasswordAlert = false
    @State var exportErrorMessage: String?

    @State var showImportFileImporter = false
    @State var winSCPTransferAction: WinSCPTransferAction?
    @State var pendingWinSCPImport: SessionExportPayload?
    @State var detectedWinSCPData: Data?
    @State var detectedWinSCPFileName = ""
    @State var detectedLoginImportData: Data?
    /// Bytes read from the chosen import file, held between the initial
    /// `probe` and the (optional) password prompt's `decode` attempt.
    @State var importFileData: Data?
    @State var showImportPasswordSheet = false
    /// A successfully decoded payload waiting to be planned and applied
    /// (M19/T8). Planning can open the conflict sheet, and SwiftUI presents
    /// only one sheet per view at a time — so an import that came through the
    /// password prompt decodes while that prompt is up and plans only once it
    /// has closed. Without the split, the conflict sheet would never appear
    /// and the password sheet would wait on it forever.
    @State var pendingImport: PendingSessionImport?
    /// Bridges the shared `ImportConflictSheet`'s callbacks to the
    /// `ImportConflictArbiter`'s decider for SESSION imports (login-set
    /// imports own an instance of the same bridge inside `LoginSetsSheet`).
    @State var importConflictBridge = ImportConflictBridge()
    @State var importResultMessage: String = ""
    @State var showImportResultAlert = false
    @State var importErrorMessage: String?

    // MARK: - Import from another program (Cyberduck import, 2026-09-03)

    /// The loaded preview the import sheet is showing, or nil while no such
    /// import is running. Built and LOADED by `presentExternalImport(folder:
    /// securityScoped:)` — which `beginExternalImport()` and the picker
    /// completion both reach — before the sheet is presented (design §4), so
    /// a missing default folder can raise the picker below instead of an
    /// error inside a sheet, and the sheet itself starts nothing when it
    /// appears. Written on the main actor after an `await`: the folder read
    /// itself runs off it.
    @State var externalImport: ImportFromSourceViewModel?
    /// The folder picker shown when the source's own bookmark folder is not
    /// where it should be (the program is not installed, or its data lives
    /// elsewhere). `.folder` rather than a file type: what is picked is the
    /// directory the source reads its bookmarks out of.
    @State var showExternalImportFolderPicker = false

    // MARK: - External terminal (M11d/T2)

    /// Set by `performExternalOpen` on `ExternalTerminalLauncher.LaunchError`
    /// — drives the error alert below (spec §4 item 7).
    @State var externalTerminalErrorMessage: String?
    /// Set when a shell-only command (⌘T/toolbar Terminal button, or the
    /// "Terminal" menu's two entries) is invoked while the active tab's
    /// backend has no shell (M12/T7b, e.g. an S3 session) — drives the
    /// alert below. Both the toolbar button and the menu bridge closures are
    /// ALSO disabled for this condition (belt-and-suspenders): this message
    /// is the "no silent no-op" fallback for any path that reaches the
    /// action despite the disabled state.
    @State private var terminalUnavailableAlertMessage: String?

    init(
        settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter, auditStore: AuditLogStore,
        settingsBridge: SettingsWindowBridge? = nil,
        tabCommands: TabCommands? = nil,
        menuBarModel: MenuBarStatusModel,
        sessionListViewModel: SessionListViewModel? = nil,
        secretStore: (any SecretStore)? = nil,
        managedKeyStore: ManagedKeyStore? = nil,
        seed: WindowSeed? = nil,
        restorationLaunch: WindowRestorationLaunch? = nil,
        errorNotifier: ErrorNotifier? = nil,
        sidebarTabFactory: (@MainActor () -> SessionTab)? = nil,
        launchLanguage: AppLanguage? = nil
    ) {
        self.errorNotifier = errorNotifier ?? ErrorNotifier.silent()
        self.sidebarTabFactory = sidebarTabFactory
        self.seed = seed
        // No restoration STORE here (Task 5 fix round 1): a window neither
        // reads nor writes `windows.json`. It is read once in
        // `MacSCPApp.init` and written once in
        // `AppDelegate.applicationWillTerminate`; what a window offers is
        // `describeThisWindow()`, through the closure it hands
        // `TabRegistry.registerWindowDescriber(_:for:)`.
        self.restorationLaunch = restorationLaunch
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
        self.auditStore = auditStore
        _tabCommands = State(initialValue: tabCommands ?? TabCommands())
        self.settingsBridge = settingsBridge ?? SettingsWindowBridge()
        self.launchLanguage = launchLanguage ?? settingsStore.selectedLanguage
        self.menuBarModel = menuBarModel
        _sidebarOpeningWidth = State(initialValue: CGFloat(settingsStore.sidebarWidth))
        let initialTab = Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)
        initialTab.overviewGroupID = SessionGroupCatalog.allConnectionsID
        _tabsModel = State(initialValue: TabsViewModel(initial: initialTab))
        // Test seam (connection-liveness plan, Task 6 fix round 2, review-
        // mandated; `secretStore`/`managedKeyStore` added in fix round 3,
        // review item "the seam is only half there" — `ContentView` still
        // built its OWN `KeychainSecretStore()`/`ManagedKeyStore(directory:
        // SessionStore.defaultDirectory)` at two other call sites,
        // `maybeCreateNewLoginSet(from:editedSession:)` and the ad-hoc
        // "save as session" path inside `startSession`, both reachable by
        // a test exercising private-key auth). Every one of these three
        // parameters defaults to `nil`, which preserves production
        // behavior byte-for-byte — `MacSCPApp.swift`, the one production
        // call site, passes nothing for any of them, so production still
        // gets the real, Keychain- and default-directory-backed instances
        // built here exactly as before these parameters existed. Passing
        // non-nil values is how a test points the whole session store, the
        // Keychain read `maybeCreateNewLoginSet`/`startSession` make to
        // check for a managed-key passphrase, and the managed-key store
        // itself at a temporary directory and an in-memory `SecretStore`
        // instead — the seam that makes it possible for a `ContentView`-
        // level test to exist at all without touching this machine's real
        // keychain or real `sessions-v2.json`. `secretStore`/
        // `managedKeyStore` resolve FIRST, so a test that supplies them but
        // leaves `sessionListViewModel` as `nil` still gets a default
        // `SessionListViewModel` built from the SAME resolved `secretStore`
        // — one isolated secret store for the whole window, not two that
        // could silently disagree.
        //
        // Built as INITIAL values here, at construction, rather than
        // properties a test reassigns afterward: an `@State` property's
        // `wrappedValue` setter is documented as requiring installation
        // into a live SwiftUI view graph to persist a mutation, which
        // nothing in this project's test suite ever does (see
        // `LivenessGiveUpOrderingTests`' own doc comment on that same
        // boundary) — measured directly while building fix round 2:
        // reassigning `view.sessionListViewModel` from a test, then
        // reading it back with no intervening call, still returned the
        // ORIGINAL value `ContentView.init` built. Choosing the initial
        // value here sidesteps that limitation entirely, since it is a
        // plain constructor argument, not a later mutation. `secretStore`/
        // `managedKeyStore` are plain `let` properties, not `@State` —
        // unlike `sessionListViewModel` they are never reassigned after
        // `init`, so they need none of `@State`'s machinery and the same
        // limitation does not apply to them; they are included in this
        // same paragraph because they are resolved alongside it, not
        // because they share its risk.
        let resolvedSecretStore: any SecretStore = secretStore ?? KeychainSecretStore()
        self.secretStore = resolvedSecretStore
        let resolvedKeyStore = managedKeyStore
            ?? ManagedKeyStore(directory: SessionStore.defaultDirectory)
        self.managedKeyStore = resolvedKeyStore
        // Named in full because `SessionListViewModel.init` no longer
        // defaults any of its stores. What each one is here, precisely —
        // this branch is NOT production-only, and reading it as such is the
        // mistake this comment exists to prevent:
        //
        // - `store:` and `loginSetStore:` are hardwired to
        //   `SessionStore.defaultDirectory`. Nothing else can be passed in
        //   at this level, and `SessionListViewModel.init` calls
        //   `reload()` — so a test that constructs `ContentView` and leaves
        //   `sessionListViewModel:` nil (still the parameter's default)
        //   reads the running user's real `sessions-v2.json` and
        //   `logins.json`. That is the residual the store-capability commit
        //   did NOT close: it made omitting a store a compile error one
        //   level down, in `SessionListViewModel`, not here.
        // - `secrets:` and `keys:` are `resolvedSecretStore` /
        //   `resolvedKeyStore`, i.e. whatever a test injected — the SAME
        //   resolved stores the rest of the view uses, not second ones
        //   built here.
        // - `auditStore:` is a required `ContentView.init` parameter, so it
        //   is whatever the caller passed; every `ContentView(` under
        //   `Tests/` passes one built on a directory the test itself made
        //   — nine constructions, counted with `grep` on 2026-09-18 in the
        //   pass that added `JumpTwoTabsTests`.
        //
        // The way to close the residual is to make the two hardwired stores
        // parameters as well, so that omitting them cannot compile. Until
        // then this is a runtime hazard, not a type-level guarantee.
        let resolvedSessionList = sessionListViewModel ?? SessionListViewModel(
            store: SessionStore(directory: SessionStore.defaultDirectory),
            secrets: resolvedSecretStore,
            auditStore: auditStore,
            loginSetStore: LoginSetStore(directory: SessionStore.defaultDirectory),
            keys: resolvedKeyStore
        )
        // A deleted session takes its forwarding profiles with it
        // (port-forwarding plan, Task 1 hand-off). Registered here because
        // this is where the App builds the view model, and additively
        // through `addDeletionObserver(_:)` — the same seam the audit log's
        // own cleanup uses — so nothing about `delete(_:)` has to know that
        // forwardings exist. What is registered is the MANAGER's observer,
        // not the store: it stops that session's runners before deleting
        // their profiles (round 1 registered the store, which rewrote
        // `tunnels.json` and left the tunnels running). It swallows its own
        // throw, like every other cleanup on that path — an orphaned profile
        // is a residual, never a reason to fail a session deletion.
        resolvedSessionList.addDeletionObserver(TunnelManager.shared.deletionObserver)
        _sessionListViewModel = State(initialValue: resolvedSessionList)
    }

    /// The mounted tab. Every view below renders THIS tab's state; switching
    /// tabs re-resolves all of it (sheet, banners, queue bar, toolbar).
    var activeTab: SessionTab { tabsModel.activeTab }

    /// The PRIMARY window is the one SwiftUI opened for the value-keyed
    /// `WindowGroup` with no seed (`MacSCPApp.primaryWindow()`). The local
    /// What's New sheet belongs to it alone: a second window presenting
    /// that process-wide decision would show the same release notes twice.
    var isPrimaryWindow: Bool { seed == nil }

    /// The AppKit autosave name under which the primary window's frame is
    /// remembered — see `applyFrameAutosave(to:)`. One constant, read at the
    /// single call site, so the string cannot come to differ between the
    /// place that writes the frame and the place that reads it.
    static let primaryFrameAutosaveName = "macSCP.primary"

    /// "Fresh window" state: a single, unconnected tab. Drives the compact
    /// form geometry — with a second tab around, the window keeps its
    /// browser size even while the active tab shows a form.
    var isPristine: Bool {
        tabsModel.isLastTab && !tabsModel.activeTab.isConnected
    }

    /// Mirrored into `tabCommands.isActiveTabConnected` via `.onChange` below
    /// (M11d/T2) — `MacSCPApp`'s "Terminal" menu lives in a separate Scene
    /// that doesn't observe `tabsModel`, so this is the value it reads to
    /// enable or disable its external terminal command.
    private var isActiveTabConnected: Bool { activeTab.isConnected }

    /// Mirrored into `tabCommands.activeTabSupportsShell` via `.onChange`
    /// below (M12/T7b), same rationale/mechanism as `isActiveTabConnected`
    /// above — the active tab's backend has no shell for an S3 session, and
    /// `MacSCPApp`'s "Terminal" menu needs to know that too.
    var activeTabSupportsShell: Bool {
        BackendDescriptor.descriptor(for: activeTab.connectionViewModel.kind).capabilities.supportsShell
    }

    var body: some View {
        // Split from `mainContent` (M11d/T2 build fix): the External
        // Terminal `.onChange`/two `.alert`s below, chained directly onto
        // the already-large modifier chain, made the type checker time out
        // ("unable to type-check this expression in reasonable time") —
        // splitting the chain into two smaller expressions fixes that
        // without changing behavior.
        mainContent
            .environment(\.groupColorsEnabled, settingsStore.groupColorsEnabled)
            .environment(\.highContrast, settingsStore.highContrast)
            .environment(\.usedGroupColors, Set(sessionListViewModel.groups.compactMap(\.color)
                + TunnelManager.shared.allGroups.compactMap(\.color)))
            // Keeps `tabCommands.isActiveTabConnected` in sync (M11d/T2) —
            // see that property's doc comment for why `MacSCPApp`'s
            // "Terminal" menu needs this mirrored instead of reading
            // `tabsModel` directly. `initial: true` seeds it once at first
            // render too, not just on later transitions.
            .onChange(of: isActiveTabConnected, initial: true) { _, newValue in
                tabCommands.isActiveTabConnected = newValue
            }
            .onChange(of: tabsModel.activeTab.id) { _, _ in
                // Selecting a new, unconnected tab reveals the session picker.
                isSidebarVisible = SidebarVisibilityPolicy.selectingTab(
                    isVisible: isSidebarVisible, hasSession: activeTab.session != nil)
            }
            // Keeps `tabCommands.activeTabSupportsShell` in sync (M12/T7b) —
            // see that property's doc comment; mirrors `isActiveTabConnected`
            // above for the identical reason.
            .onChange(of: activeTabSupportsShell, initial: true) { _, newValue in
                tabCommands.activeTabSupportsShell = newValue
            }

            // Keeps `tabCommands.keepOnTop` in sync (Detachable Tabs plan,
            // Task 4) — same mirror shape as the three above, and applies
            // `WindowLevelPlan`'s decision to THIS window's `NSWindow` in
            // the same place: `window` may still be nil at the `initial:
            // true` firing (before `WindowAccessor` has resolved it), in
            // which case this is a no-op and the `WindowAccessor` closure
            // in `windowChrome(_:)` is what applies the level once the
            // window exists.
            .onChange(of: keepOnTop, initial: true) { _, newValue in
                tabCommands.keepOnTop = newValue
                window?.level = WindowLevelPlan.level(keepOnTop: newValue)
            }
            // Mirrors `hiddenImportAliases.count` into the command bridge
            // (M11f/T2, same rationale as `isActiveTabConnected` above):
            // `MacSCPApp`'s "Sessions" menu lives in a separate Scene that
            // doesn't observe this view's `@State`, so the "Hidden
            // Imports…" title's count suffix has to be mirrored here too.
            .onChange(of: hiddenImportAliases.count, initial: true) { _, newValue in
                tabCommands.hiddenImportsCount = newValue
                settingsBridge.hiddenImportsCount = newValue
            }
            // External-terminal launch failures (M11d/T2, spec §4 item 7):
            // `ExternalTerminalLauncher.LaunchError` is mapped to a concrete
            // message (app name/path, or the write-failure reason) in
            // `performExternalOpen` below.
            .alert(
                L10n.string("externalTerminal.error.title", "Couldn't Open External Terminal"),
                isPresented: externalTerminalErrorPresented
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(externalTerminalErrorMessage ?? "")
            }
            // Shell-only shortcut invoked on a non-shell backend (M12/T7b) —
            // see `terminalUnavailableAlertMessage`'s doc comment.
            .alert(
                L10n.string("shortcut.unavailableForProtocol.title", "Not Available"),
                isPresented: Binding(
                    get: { terminalUnavailableAlertMessage != nil },
                    set: { isPresented in if !isPresented { terminalUnavailableAlertMessage = nil } })
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(terminalUnavailableAlertMessage ?? "")
            }
    }

    // MARK: - Connecting

    // MARK: - Login sets (M10b/T3)

    /// The outcome of the optional login-set creation performed before a
    /// connection is saved. Failure is distinct from "not requested": a
    /// failed credential write must abort the connection save instead of
    /// silently falling back to a session-owned secret.
    enum NewLoginSetSaveResult: Equatable {
        case notRequested
        case saved(UUID)
        case failed
    }

    /// Manual mode + "Save as new login set": creates the set from the
    /// form's current fields and returns its result. The name is the field's trimmed value, or
    /// `suggestedSetName(forLabel:)` when left blank (spec §3).
    ///
    /// `editedSession` is the session being edited when this runs from the
    /// edit-save path (`nil` for a brand-new connection). In edit mode
    /// `form.password` is intentionally empty ("leave empty to keep the
    /// existing secret" — see `ConnectionViewModel.beginEditing`), so an
    /// empty field here does NOT mean "no secret": it means the session's
    /// existing keychain secret must MOVE onto the new set rather than be
    /// dropped, or the session becomes unreachable after the rewire (B1).
    ///
    /// M17 review fix: a managed key's passphrase lives in the Keychain
    /// under its own `key.id` slot (`ManagedKeyPassphrase.resolve`'s doc
    /// comment) -- a session's or login set's own secret slot must never
    /// duplicate it. The decision of whether that applies now lives in
    /// `SessionSecretPolicy.usesStoredManagedPassphrase` (Core), which this
    /// function calls with `ContentView`'s own `managedKeyStore`/
    /// `secretStore` (real Keychain-backed in production, test-seamed —
    /// fix round 3 — otherwise); see that type's doc comments for why an
    /// unanswerable probe counts as "has a slot" rather than "does not".
    func maybeCreateNewLoginSet(
        from form: ConnectionViewModel, editedSession: StoredSession? = nil
    ) -> NewLoginSetSaveResult {
        guard form.loginMode == .manual, form.saveAsNewLoginSet else {
            return .notRequested
        }

        // One path for every protocol (M22/T9). The `if form.kind == .s3`
        // branch this replaces was the only kind-aware one: everything else
        // fell through to a generic branch building
        // `LoginSet(name:username:authKind:keyPath:)`, whose `kind` DEFAULTS
        // to `.ssh` — so a WebDAV form would have written WebDAV credentials
        // into an SSH-kind set, invisible in the kind-filtered picker that
        // would then have to offer it. M22/T7 kept this control S3-only to
        // keep that unreachable; asking the descriptor to build the set is
        // what makes it correct instead of merely unreachable.
        let descriptor = BackendDescriptor.descriptor(for: form.kind)
        let trimmedName = form.newLoginSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The suggested name is the login's own identity: whichever field the
        // backend marks as identifying it (`username`, `accessKeyID`) — read
        // back off the set the descriptor just built, so this needs no branch.
        let draft = descriptor.loginSet(id: UUID(), name: "", from: form.values)
        let name = trimmedName.isEmpty
            ? sessionListViewModel.suggestedSetName(
                forLabel: draft.accessKeyID ?? draft.username)
            : trimmedName
        let newSet = descriptor.loginSet(id: draft.id, name: name, from: form.values)

        // The secret is whichever field the backend's credential schema shows
        // right now — SSH's password row under password auth, its passphrase
        // row under private-key auth, and NOTHING for an agent login, whose
        // set never carries a secret (M10d/T4). `saveLoginSet` already refuses
        // to write one for `.agent`; resolving to "no secret field" here also
        // skips the (then-discarded) keychain lookup for the edited session's
        // own secret.
        let typed = descriptor.credentialSchema.visibleSecretField(
            in: form.values, namespace: descriptor.fieldNamespace)
            .map { form.values.raw["\(descriptor.fieldNamespace).\($0.id)"] ?? "" }
        let carried: String? = typed == nil ? nil
            : SessionSecretPolicy.usesStoredManagedPassphrase(
                kind: form.kind, authChoice: form.authChoice, keyPath: form.keyPath,
                keys: managedKeyStore,
                secrets: secretStore) ? ""
            : ((typed ?? "").isEmpty
                ? (editedSession.flatMap { sessionListViewModel.password(for: $0) })
                : typed)
        guard sessionListViewModel.saveLoginSet(newSet, secret: carried) else {
            return .failed
        }
        return .saved(newSet.id)
    }

    /// Writes what a form holds as a NEW stored session, and nothing else —
    /// no tab bookkeeping, no window title, no connection.
    ///
    /// Lifted out of `startSession` in the tab-context-menu fix round: this
    /// code used to live inside that function's `shouldSaveSession` branch,
    /// which made "remember this connection" reachable only through the
    /// success path of a dial. A user whose ad-hoc connection was already
    /// running could not have it saved without opening a second one to the
    /// same server. Separating the two is what lets the form's own Save
    /// button (`saveFormAsSession(in:)`) write a session with no connection
    /// attempt at all, WITHOUT a second persistence path beside this one —
    /// both callers run exactly these lines.
    ///
    /// What the caller still owns is what differs between them: binding the
    /// tab to the result, the window title, and clearing
    /// `shouldSaveSession`.
    ///
    /// Set mode references the picked login set directly. Manual mode +
    /// "Save as new login set" creates the set FIRST, then references it —
    /// either way `password:` is safely ignored by `save` once `loginSetID`
    /// is non-nil (see its doc comment).
    ///
    /// ONE save for every protocol (M23/T7), and the place the last two
    /// `"unused"` placeholders died: the backend's own adapter writes its
    /// own fields out of `form.values`, so this call site does not know that
    /// S3 has a bucket and SSH has a port -- nor parks a literal in
    /// `host`/`username` for a backend that has neither.
    ///
    /// What the three branches it replaced did, and where it went:
    /// * S3/WebDAV built a `StoredS3Config`/`StoredWebDAVConfig` from the
    ///   form -> `descriptor.apply` inside `save`.
    /// * Each named its own secret field -> `SessionSecretPolicy.
    ///   valueToPersist`, which now asks the schema which row is the visible
    ///   secret.
    /// * The SSH branch alone passed `authKind`/`keyPath` -> both live in
    ///   `form.values` and are written by SSH's own `apply`.
    /// * S3/WebDAV passed NO jump and NO jump secret; the SSH branch passed
    ///   `form.buildJumpSpec()` (no `existingSecretID`: this is a brand-new
    ///   session, unlike `validateForEditSave`'s own call) and suppressed the
    ///   jump secret in session mode (spec §1: the `secretID` slot stays
    ///   unused while `sessionID` is set). Both survive verbatim --
    ///   `buildJumpSpec()` returns nil unless `jumpEnabled`, which the S3 and
    ///   WebDAV forms never offer, so the hardcoded `nil` those two branches
    ///   carried needs no `kind` check here.
    func persistFormAsSession(_ form: ConnectionViewModel) -> StoredSession? {
        let loginSetResult = maybeCreateNewLoginSet(from: form)
        guard loginSetResult != .failed else { return nil }
        let newSetID: UUID? = switch loginSetResult {
        case .saved(let id): id
        case .notRequested, .failed: nil
        }
        return sessionListViewModel.save(
            name: form.saveName.trimmingCharacters(in: .whitespacesAndNewlines),
            values: form.values,
            password: SessionSecretPolicy.valueToPersist(
                resolvedSecret: form.resolvedSecret, kind: form.kind, authChoice: form.authChoice,
                keyPath: form.keyPath,
                keys: managedKeyStore,
                secrets: secretStore),
            kind: form.kind,
            groupID: form.selectedGroupID,
            loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID,
            jump: form.buildJumpSpec(),
            jumpSecret: form.jumpSourceMode == .session ? nil : form.jumpPassword,
            filledJumpPassphrase: form.filledJumpPassphrase,

            appearance: form.appearance)
    }

    /// The connection form's own "Save" button, outside edit mode: write
    /// what is on screen as a stored session **without dialing**.
    ///
    /// This is what makes the tab menu's "Save as Session…" honest. That
    /// entry prefills this form from a connection that is already up; before
    /// this button existed the only way to get the form's contents into
    /// `sessions.json` was to press Connect, so remembering a running
    /// connection meant opening a second one to the same server and saving
    /// THAT.
    ///
    /// The rules come from `ConnectionViewModel.validateForNewSave()` (run
    /// by the button itself, so a refusal highlights the offending field the
    /// way Connect's does) and the write from `persistFormAsSession`, the
    /// same lines a saved connect runs. A `nil` result means
    /// `SessionListViewModel.save` refused — it has already published its
    /// own `errorMessage`, which the sidebar shows, exactly as for a saved
    /// connect.
    ///
    /// Afterwards the form goes into EDIT mode on the session it just wrote,
    /// rather than staying a "new connection" form holding the same values a
    /// second time. Three things follow from that, all of them wanted:
    /// pressing Save again updates that session instead of writing a
    /// near-duplicate under a new id; "Save & connect" is right there for a
    /// user who did want to open it as well; and `beginEditing` rebuilds
    /// `values` from the stored session, which means the plaintext secret
    /// copied in from the running connection is gone from this form the
    /// moment it has been written to the keychain — the form's own
    /// empty-means-unchanged rule takes over from there.
    func saveFormAsSession(in tab: SessionTab) {
        let form = tab.connectionViewModel
        guard let stored = persistFormAsSession(form) else { return }
        form.shouldSaveSession = false
        form.beginEditing(stored)
    }

    func startSession(
        in tab: SessionTab, with fs: any RemoteFileSystem, storedName: String? = nil,
        startPath: String = "/"
    ) {
        // Clear any stale edit error from a previous session so a late
        // openInEditor task cannot misattribute its failure to this session.
        tab.editErrorMessage = nil
        let form = tab.connectionViewModel
        // One UUID, shared by the session and its edit manager (M5e/T4) — see
        // `BrowserSession.id`'s doc comment.
        let sessionID = UUID()
        let queue = tab.transferQueue
        // Only pay for the per-entry `FileManager.attributesOfItem` syscall
        // (and the macOS permission prompt it can trigger on Desktop/
        // Documents/Downloads) when the owner or group column is actually
        // visible (M18a). Read once at session start: the local file system
        // is built here and lives for the session's lifetime, so a
        // visibility change made in Settings while this session is already
        // open takes effect on the NEXT connect, not live — acceptable for
        // this fix, matching how `visibleColumns` is otherwise threaded
        // through as a snapshot at each call site.
        let wantsOwnerGroup = settingsStore.visibleColumns.contains(.owner)
            || settingsStore.visibleColumns.contains(.group)
        // One `StuckPaths` per session, shared by both `LocalFileSystem`
        // instances below (local-listing-never-blocks final fix round): a
        // path either instance's `metadata(for:)` proves stuck is then
        // skipped by the OTHER instance too, so the tester's own home
        // folder — the folder one keeps returning to — does not spend a
        // fresh thread rediscovering the same stuck entry on every visit.
        let stuckPaths = StuckPaths()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup, stuckPaths: stuckPaths),
            remoteFS: fs,
            local: RemoteBrowserViewModel(
                fs: LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup, stuckPaths: stuckPaths),
                startPath: NSHomeDirectory(),
                logCategory: "browser.local"),
            remote: RemoteBrowserViewModel(fs: fs, startPath: startPath, logCategory: "browser.remote"),

            editManager: EditSessionManager(sessionID: sessionID, queue: queue),
            // Both callers of `startSession` already resolved this via
            // `homeDirectoryPath()` before calling in (see this function's
            // own `startPath` parameter doc comment) — captured here too for
            // the liveness probe, see `BrowserSession.homePath`'s doc comment.
            homePath: startPath
        )
        // Fresh liveness for a fresh session (Task 4, fix round 1):
        // `SessionTab.liveness` lives on the tab, not the session (see that
        // property's own doc comment for why), so it needs its own reset
        // here rather than getting one for free from `BrowserSession`'s
        // memberwise init the way it used to.
        tab.liveness = .connected
        // A fresh session has no failed probe behind it (lost-connection
        // cause, 2026-09-19); see `SessionTab.lastProbeFailure`.
        tab.lastProbeFailure = nil
        // Its SSH connections' closes go to the diagnostic log, named by
        // this tab's id (lost-connection cause, 2026-09-19). Observation
        // only: the handler captures the id, not the tab and not `fs`, so
        // it keeps nothing alive, and teardown still owns the close.
        if let reporting = fs as? TransportCloseReporting {
            let tabID = tab.id
            reporting.onTransportClose { event in
                DiagnosticLog.shared.log(
                    .info, "connect", LivenessLogLines.transportClosed(tab: tabID, event: event))
            }
        }
        // Nothing left to describe (connection-liveness plan, Task 7): this
        // tab has a live session again, so the record of the connection
        // that dropped — including the attempt counter an unattended
        // schedule was pacing itself by — goes with the state it explained.
        // A later drop starts a fresh episode from `handleLivenessGiveUp`,
        // at attempt zero.
        tab.lostConnection = nil
        // Hidden-files toggle (M7a/T4): applied once here at session start,
        // kept in sync afterwards by the `.onChange` observer above.
        tab.session?.local.showHiddenFiles = settingsStore.showHiddenFiles
        tab.session?.remote.showHiddenFiles = settingsStore.showHiddenFiles
        // The tab's queue is created ONCE (in `SessionTab.init`, together with
        // its limiter/concurrency/decider wiring) and OUTLIVES each session of
        // that tab (M5d/T3): interrupted transfers stay in the bar across a
        // disconnect/reconnect so `retryInterrupted` can resume them.

        // Grow the window to the browser size (user feedback 2026-07-10,
        // M5c/T0) — to the remembered browser size, if any and larger than
        // the minimum size, and never smaller than the window already is.
        // The decisions are `MainWindowSizePlan`'s; see `growToBrowserSize()`.
        growToBrowserSize()

        var titleName = storedName
        // M31: hoisted out of the branch below so the audit recorder can be
        // attached for BOTH cases -- see the comment at the attach itself.
        var storedSession: StoredSession?
        if form.shouldSaveSession {
            let stored = persistFormAsSession(form)
            storedSession = stored
            tab.activeStoredSessionID = stored?.id
            form.shouldSaveSession = false
            titleName = stored?.name ?? titleName
        }

        // Audit recorder (M9b/T3, un-nested in M31). This used to sit INSIDE
        // the branch above, so the audit trail depended on whether the
        // connection was SAVED rather than on whether it happened: an
        // unsaved connect logged nothing at all -- not even the M21
        // plaintext-transport note, which `attachAuditRecorder` writes.
        // `AdHocAudit.logSessionID` supplies the fixed id for that case.
        //
        // `displaySummary` (M22/T11), not host/username directly: a legacy S3
        // or WebDAV session still carries the `"unused"` placeholder in those
        // two (a freshly saved one no longer does, since M23/T7), which is
        // what used to leave "connected to unused as unused" in the audit
        // trail for anything but SSH. The saved case keeps reading it from
        // the SESSION verbatim, so nothing about an existing session's log
        // changes; only the ad-hoc case reads the form, which is its only
        // source.
        //
        // `form.jumpHost` (M-1 fix, final review), not `stored.jump?.host`:
        // for a session-mode jump `form.jumpHost` already holds the freshly
        // resolved host (`SessionListViewModel.resolveJumpSession` filled it
        // before `connect()` ran, a few lines above `buildJumpSpec()` reads
        // the very same field) -- using `stored.jump?.host` instead happened
        // to read the identical value here (it's the trimmed copy of this
        // same field), but only by accident, not by construction;
        // `form.jumpHost` is the one field guaranteed to be current in both
        // connect paths.
        let auditDescriptor = BackendDescriptor.descriptor(
            for: storedSession?.kind ?? form.kind)
        attachAuditRecorder(
            to: tab,
            sessionID: AdHocAudit.logSessionID(storedID: storedSession?.id),
            summary: storedSession.map {
                auditDescriptor.displaySummary(auditDescriptor.sessionValues($0))
            } ?? auditDescriptor.displaySummary(form.values),
            viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)

        // Tab/window title: a stored session's name when this connection is
        // actually backed by one (just saved above, or passed in by
        // `connect(in:stored:)`), otherwise the backend's own `displaySummary`
        // (M22/T11) — NOT the old hand-rolled "\(form.username)@\(form.host)",
        // which read SSH-only fields and left a WebDAV tab titled "tim@" (its
        // real user name lives on `WebDAVField.username`, its host on
        // `SSHField.host` was simply never written). Window chrome (proper
        // name + user data), deliberately not localized (no catalog key).
        tab.titleName = titleName?.isEmpty == false
            ? titleName!
            : BackendDescriptor.descriptor(for: form.kind).displaySummary(form.values)
    }

    /// Completes the AD-HOC connect form's own attempt after
    /// `ConnectionViewModel.connect()` has already succeeded (connection-
    /// liveness plan, Task 6 fix round 2) — `ContentView.detail`'s
    /// `onConnected` closure calls this instead of inlining the hand-off,
    /// so `Tests/macSCPAppKitTests/` can drive it directly (the same move
    /// `handleLivenessGiveUp(_:)` made for the probe's give-up path — see
    /// that method's own doc comment).
    ///
    /// `attempt` is `tab.reconnectAttempt`'s value the CALLER captured the
    /// moment its closure started running, before `fs.homeDirectoryPath()`
    /// — not read fresh in here, which would defeat the whole point: Cancel
    /// moves `tab.reconnectAttempt` unconditionally (see that property's
    /// own doc comment) the instant it runs, and the guard below only means
    /// something if it compares against a value captured BEFORE the
    /// vulnerable `await`, not after.
    ///
    /// The bug this closes (Critical, fix round 2 review): `form.connect()`
    /// already refuses to hand back a result for an attempt Core itself
    /// superseded, but by the time `fs` reaches this function `Connection
    /// ViewModel.state` has already moved to `.idle` — the dial succeeded —
    /// so a Cancel that lands during `fs.homeDirectoryPath()` below is
    /// invisible to Core entirely. Left ungated, `startSession` would run
    /// unconditionally: it sets `tab.session`, publishes `.connected`, and —
    /// with the form's "save as session" toggle on — persists a NEW
    /// `StoredSession` and writes its secret to the keychain, all for a
    /// connection the user had already clicked Cancel on.
    func handleAdHocConnected(
        _ fs: any RemoteFileSystem, in tab: SessionTab, attempt: UUID
    ) async {
        // Remote home start (M9d): resolved once per connect, right before
        // the browser session is built, so the remote pane opens where the
        // user actually lands after login instead of hardcoded "/". A
        // lookup failure (older SFTP servers, permission quirks) falls back
        // to "/" rather than failing the connect.
        // Accept only usable absolute paths (M9d final review): an
        // empty/relative realpath result would land the pane in .failed
        // where "/" always worked.
        let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
        let home = resolved.hasPrefix("/") ? resolved : "/"
        guard tab.reconnectAttempt == attempt else {
            // The dial itself succeeded — `fs` is a live, open connection —
            // but the hand-off it was for has been superseded. Nothing
            // else owns this connection: `tab.session` is (and stays) nil
            // on this path, so the only other place a `disconnect()` call
            // could come from — `teardown(_:)`, gated on `tab.session !=
            // nil` — will never reach it, and `deinit` cleanup is against
            // this project's own rules (see the architecture invariants).
            // Left uncalled, the connection the user cancelled would stay
            // open on the remote host until the whole process exits
            // (fix round 3, review-measured).
            await fs.disconnect()
            return
        }
        startSession(in: tab, with: fs, startPath: home)
    }

    @discardableResult
    func connectFromSidebar(
        _ stored: StoredSession
    ) -> AlreadyOpenSessionRequest? {
        sidebarStart(stored)
    }

    /// Opens the stored connection in the configured external terminal.
    func openTerminalFromSidebar(_ stored: StoredSession) {
        openExternalTerminalFromSidebar(stored)
    }

    /// What a sidebar row's start actually does ("Sitzung ist schon offen",
    /// C2): when a tab already holds this stored session, raise the query
    /// and start nothing; otherwise go ahead exactly as before.
    ///
    /// Identity is `SessionTab.activeStoredSessionID` and nothing else —
    /// an ad-hoc connection to the same host never counts, because a typed
    /// connection can carry other credentials, another key, another jump
    /// host. Comparing hosts would be guessing at an equality this program
    /// does not know.
    ///
    /// The ACTIVE tab holding the session is not a special case: the query
    /// is raised for it too, and jumping is then a no-op — the right effect
    /// of that choice rather than a reason to withhold it, since "open
    /// another one" means exactly what it means anywhere else.
    ///
    /// Reconnecting in place never reaches here (`reconnect(_:)` calls
    /// `connect(in:stored:)` directly), which is correct: that is the same
    /// tab, and nothing about it is doubled.
    ///
    /// **The return value is what the query would be raised with.** It is
    /// discardable and every caller in this file discards it. Setting the
    /// `@State` is the one line no test of this project can observe — a
    /// `ContentView` built outside a SwiftUI hierarchy drops writes to
    /// `@State` (measured in `ConnectAttemptHandoffTests`' "Isolation,
    /// round 2") — so the value it would be set to is handed back instead
    /// of only being parked, and `AlreadyOpenSessionTests` reads it there.
    @discardableResult
    func sidebarStart(
        _ stored: StoredSession
    ) -> AlreadyOpenSessionRequest? {
        guard let existing = tabsModel.tabHolding(
            stored.id, storedSessionIDOf: \.activeStoredSessionID)
        else {
            startWithoutAsking(
                stored)
            return nil
        }
        let request = AlreadyOpenSessionRequest(
            stored: stored, existingTabID: existing.id)
        alreadyOpenRequest = request
        return request
    }

    func startWithoutAsking(
        _ stored: StoredSession
    ) {
        let target = tabsModel.sidebarConnectTarget(
            activeTabIsConnected: activeTab.isConnected, makeTab: makeSidebarTab)
        connect(in: target, stored: stored)
    }

    /// The fresh tab `startWithoutAsking`'s tab rule asks for: the window's
    /// own `makeTab()` — the real connector — unless a test handed
    /// `init` a `sidebarTabFactory`.
    func makeSidebarTab() -> SessionTab {
        sidebarTabFactory?() ?? makeTab()
    }

    /// "Go to Existing Tab" — the whole of that choice.
    ///
    /// It closes nothing and merges nothing: the other tab keeps its
    /// session, and this window simply looks at it. When the tab named here
    /// is already the active one, activating it changes nothing, which is
    /// what that answer means in that situation.
    func jumpToOpenSession(_ request: AlreadyOpenSessionRequest) {
        tabsModel.activate(request.existingTabID)
    }

    func connect(
        in tab: SessionTab, stored: StoredSession
    ) {
        guard !tab.isReconnecting else { return }
        // Connecting to a DIFFERENT session ends the episode the lost
        // surface was describing (connection-liveness plan, Task 7): the
        // user has moved on, and a failure now belongs to what they just
        // asked for, not to the connection that dropped earlier — which
        // would otherwise send them back to a surface offering to redial
        // something else entirely. `reconnect(_:)` passes the SAME id, so
        // its own failures still return to the surface that explains them.
        if tab.lostConnection?.storedSessionID != stored.id { tab.lostConnection = nil }
        tab.isReconnecting = true // synchronous — locks this tab immediately, before the first await
        // Attempt-scoped (connection-liveness plan, Task 6 fix round 1,
        // measured by review — Critical 1): Cancel releases `isReconnecting`
        // directly rather than waiting for THIS Task's own `defer`, which
        // stays suspended on `await form.connect()` for as long as the
        // abandoned dial keeps running. Without `reconnectAttempt`, that
        // deferred release would still fire once the abandoned dial finally
        // settles — clearing `isReconnecting` for whatever attempt is
        // current AT THAT LATER MOMENT, not this one. See
        // `SessionTab.reconnectAttempt`'s own doc comment.
        let myAttempt = UUID()
        tab.reconnectAttempt = myAttempt
        // `Task<Void, Never>`, spelled out: a throw from `fillForm` must not
        // leave this task uncaught and unseen, and a non-throwing task will not
        // compile one that does (technical backlog of 2026-09-16, Task 5).
        Task<Void, Never> {
            defer {
                if tab.reconnectAttempt == myAttempt { tab.isReconnecting = false }
            }
            // Defensive only: the sidebar rule always hands over an
            // unconnected tab. Reconnecting in place still tears THIS tab's
            // session down first, never anyone else's.
            if tab.isConnected { await teardown(tab, reason: .userRequested) }
            let form = tab.connectionViewModel
            let descriptor = BackendDescriptor.descriptor(for: stored.kind)
            // ONE fill for every protocol, shared with the sidebar's
            // "Open in External Terminal" entry — see `fillForm`. A `false`
            // means it already published the reason on THIS form, which is
            // on screen, so there is nothing more to show here. A THROW is
            // not a refusal and published nothing: it goes onto this form in
            // the text the sidebar route shows for the same throw.
            do {
                guard try fillForm(form, from: stored) else { return }
            } catch {
                form.showFailure(message: error.localizedDescription)
                return
            }

            // The dial's origin (failed-connect surface plan, Task 3;
            // rebound to the attempt by the two-open-questions design, M3).
            // It travels as an argument rather than being parked on the tab
            // first: `connect(origin:)` records it only for a call it
            // actually turns into an attempt, so a dial refused because
            // this form is already connecting leaves nothing behind for a
            // later attempt to inherit. See `ConnectionViewModel
            // .attemptOrigin`.
            if let fs = await form.connect(origin: stored.id) {
                // Accept only usable absolute paths (M9d final review): an
                // empty/relative realpath result would land the pane in
                // .failed where "/" always worked.
                let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
                let home = resolved.hasPrefix("/") ? resolved : "/"
                guard tab.reconnectAttempt == myAttempt else {
                    // Same reasoning as `handleAdHocConnected`'s own
                    // refusal branch: `fs` is a live, open connection with
                    // nothing else left to close it (`tab.session` stays
                    // nil on this path, so `teardown(_:)` never reaches it,
                    // and `deinit` cleanup is against this project's own
                    // rules) — left uncalled, it would stay open until the
                    // process exits (fix round 3, review-measured).
                    await fs.disconnect()
                    return
                }
                startSession(in: tab, with: fs, storedName: stored.name, startPath: home)
                tab.activeStoredSessionID = stored.id
                // And the restored pointer with it: a connected tab shows
                // its browser, and on a later disconnect it should fall
                // back to this window's own sidebar selection rather than
                // to the session it happened to be restored with.
                tab.restoredSessionID = nil
                // Audit recorder (M9b/T3): this IS the stored-session connect
                // path — attach right after `activeStoredSessionID`, once
                // `tab.session` (set inside `startSession`) exists.
                //
                // `form.jumpHost` (M-1 fix, final review), not
                // `stored.jump?.host`: for a session-mode jump the latter is
                // the snapshot taken at SAVE time, not the host actually
                // dialed just now -- if the bastion session moved since, the
                // audit entry would record a stale carrier host, defeating
                // reference semantics. `form.jumpHost` was just resolved
                // fresh above (`resolvedJump(for:)`/the manual fallback) and
                // is correct by construction; `jumpEnabled` gates it to `nil`
                // when there is no jump at all.
                // `displaySummary` (M22/T11), not `stored.host`/`stored.username`
                // directly — a legacy non-SSH session still carries the
                // `"unused"` placeholder in those two, which is what used to
                // leave "connected to unused as unused" in the audit trail.
                // Reuses the `descriptor` the fill above already resolved.
                attachAuditRecorder(
                    to: tab, sessionID: stored.id,
                    summary: descriptor.displaySummary(descriptor.sessionValues(stored)),
                    viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)
            } else if tab.reconnectAttempt == myAttempt, let reason = form.lastFailureReason {
                // The `connectFailed` audit row (session overview plan, Task
                // 2), and the ONE place this app writes one: this is the
                // stored-session connect path, the same one `retryConnect`
                // and the lost surface's Reconnect come back through, so a
                // second appender for those would be a second chance to get
                // the sentence wrong.
                //
                // Two conditions, and each rules out a different non-event:
                //
                // * `lastFailureReason != nil` means a dial actually reached
                //   the wire and threw. `form.connect()` also answers `nil`
                //   for a refusal decided before any of that — an empty save
                //   name, a login set that no longer resolves — and for an
                //   attempt Core itself superseded. Neither is a connect that
                //   failed, and a log full of them would say this session is
                //   unreliable when nothing was ever dialled. See
                //   `ConnectionViewModel.lastFailureReason`.
                // * `tab.reconnectAttempt == myAttempt` is the same
                //   hand-off guard the success path above uses: a Cancel that
                //   landed during the dial has already moved that token, and
                //   an attempt the user backed out of leaves no record.
                //
                // The sentence is Core's fixed one, never the error's own
                // text — `DialSupport.reason(for:)` is public for exactly
                // this, and its doc comment explains what an arbitrary
                // error's description can carry out of a URL-shaped
                // endpoint field. The recorder is built here rather than
                // taken from `tab.auditRecorder`: that one is attached on a
                // SUCCESSFUL connect and is nil (or another session's) at
                // this point.
                AuditRecorder(sessionID: stored.id, store: auditStore)
                    .recordConnectFailed(reason: reason)
            }
        }
    }

    /// The stored session a lost tab's "Reconnect" would redial, or `nil`
    /// (connection-liveness plan, Task 7).
    ///
    /// Resolved against the LIVE session list every time it is asked, not
    /// remembered: `SessionTab.lostConnection` keeps only the id, because a
    /// session can be edited — or deleted — while its tab sits on the lost
    /// surface. A deleted one turns "Reconnect" off (`LostConnectionPlan
    /// .content`'s `targetIsKnown`) and stops the unattended schedule
    /// (`ReconnectPlan.step`), instead of offering a button that dials
    /// something that is no longer there.
    ///
    /// `nil` for an ad-hoc connection too — one typed into the form and
    /// never saved has no `storedSessionID` at all, and `teardown(_:)` has
    /// already cleared the form's secrets by the time this surface appears,
    /// so there is nothing left to redial with.
    func reconnectTarget(for tab: SessionTab) -> StoredSession? {
        guard let id = tab.lostConnection?.storedSessionID else { return nil }
        return sessionListViewModel.sessions.first(where: { $0.id == id })
    }

    /// Rebuilds a lost connection (connection-liveness plan, Task 7) —
    /// from the surface's "Reconnect" button and from `ReconnectRunner`'s
    /// unattended schedule alike.
    ///
    /// One line of substance, and that is the point: this dials through
    /// `connect(in:stored:)`, the SAME function a sidebar connect goes
    /// through, so TOFU stays the hard stop it is, the keychain rules are
    /// the ones `fillForm(_:from:)` already applies, the plaintext
    /// confirmation still gets asked, and the attempt token/`isReconnecting`
    /// lock still guard the hand-off. The design spec calls this out as the
    /// load-bearing decision of its recovery section: a second dial here
    /// would be a second place a security rule could be forgotten.
    /// `ReconnectWiringGuardTests` pins it by scanning this function's own
    /// comment-stripped source, and `ReconnectPathTests` drives the real
    /// call end to end.
    func reconnect(_ tab: SessionTab) {
        guard let stored = reconnectTarget(for: tab) else { return }
        connect(in: tab, stored: stored)
    }

    /// Leaves the lost surface for the ordinary connection form
    /// (connection-liveness plan, Task 7).
    ///
    /// Clears BOTH facts: `liveness` is what `ConnectionSurfacePlan` reads
    /// to pick the surface, `lostConnection` is what would otherwise send
    /// the next failed attempt straight back to it
    /// (`ConnectAttemptLivenessPlan.write`) and keep an unattended schedule
    /// alive behind a form the user is typing into.
    func dismissLostConnection(_ tab: SessionTab) {
        tab.lostConnection = nil
        tab.liveness = nil
    }

    /// The stored session this tab's FAILED ATTEMPT dialed, if it is still
    /// in the list (failed-connect surface plan, Task 3).
    ///
    /// Resolved live rather than remembered, exactly as
    /// `reconnectTarget(for:)` is and for the same reason: `ConnectFailure`
    /// keeps only an id, and a session can be deleted — from another window
    /// — while its tab sits on this surface. A deleted one turns "Edit
    /// session" off and turns Retry into the ad-hoc case, instead of
    /// offering two controls that cannot work.
    func failedConnectTarget(for tab: SessionTab) -> StoredSession? {
        guard let id = tab.connectFailure?.storedSessionID else { return nil }
        return sessionListViewModel.sessions.first(where: { $0.id == id })
    }

    /// The failed-connect surface's "Try again" (failed-connect surface
    /// plan, Task 3).
    ///
    /// One line of substance, and — as with `reconnect(_:)` above — that is
    /// the point: it dials through `connect(in:stored:)`, the SAME function
    /// a sidebar connect goes through, so TOFU stays the hard stop it is, the
    /// keychain and login-set rules are the ones `fillForm(_:from:)`
    /// applies, the plaintext confirmation still gets asked, and the
    /// attempt token and `isReconnecting` lock still guard the hand-off. A
    /// dial written out here instead would be a second place every one of
    /// those could be forgotten, which is the property
    /// `ReconnectWiringGuardTests` exists to hold.
    ///
    /// The guard is the same shape as `reconnect(_:)`'s and means the same
    /// thing: nothing to dial, so nothing happens. It is not reachable from
    /// the surface — `ConnectFailurePlan` omits the button entirely without
    /// a stored session (round 2, after review; round 1 offered it and made
    /// it return the user to the form, which is a button that does the
    /// opposite of its name). It stays because a target can be deleted from
    /// another window between the render and the click.
    func retryConnect(_ tab: SessionTab) {
        guard let stored = failedConnectTarget(for: tab) else { return }
        connect(in: tab, stored: stored)
    }

    /// Leaves the failed-connect surface for the ordinary connection form
    /// (failed-connect surface plan, Task 3) — the surface's own "Edit",
    /// and the way every sidebar command that fills the form gets past it.
    ///
    /// Clears only `connectFailure`: that is the single fact
    /// `ConnectionSurfacePlan` reads for this surface, `liveness` is
    /// already `nil` for a tab showing it, and the FORM is deliberately
    /// left exactly as the failed attempt filled it — "Edit" means "change
    /// something and try again", and blanking the fields it is named for
    /// would be the opposite.
    func dismissConnectFailure(_ tab: SessionTab) {
        tab.connectFailure = nil
    }

    /// The failed-connect surface's "Edit session" (failed-connect surface
    /// plan, Task 3): the durable change, as opposed to "Edit"'s one-off.
    ///
    /// Goes through `editStored(_:)`, the same function the sidebar's own
    /// "Edit…" entry uses, so the editor is opened one way. The surface is
    /// only ever rendered for the ACTIVE tab (`ContentView.detail` renders
    /// that one tab's content), which is the tab `editStored`'s own target
    /// rule then picks — and it picks it because a tab showing this surface
    /// is unconnected by construction.
    ///
    /// Deliberately no `dismissConnectFailure(_:)` of its own (round 2,
    /// after review): `editStored` resolves its target through
    /// `formTarget()`, which returns `nil` while a dial is in flight and
    /// then opens nothing — so clearing the surface here first would leave
    /// the tab on the form with no editor and no explanation. `formTarget()`
    /// already clears both surfaces on the path where it DOES hand a tab
    /// back, which is the one path that needs it.
    func editFailedSession(_ tab: SessionTab) {
        guard let stored = failedConnectTarget(for: tab) else { return }
        editStored(stored)
    }

    /// The failed-connect surface's "Convert key…" (PEM private keys plan,
    /// Task 4): opens the key manager's own import sheet over the PEM file
    /// the failed attempt used.
    ///
    /// The sheet is where the person types the passphrase and the name, and
    /// where the copy, the conversion, the inspection and the Keychain slot
    /// already happen — `ImportKeySheet.performImport()`, unchanged in its
    /// order by this button. Nothing about the conversion is written here.
    ///
    /// The guard is the shape `retryConnect(_:)`'s is and means the same
    /// thing: no remedy, nothing to convert. It is not reachable from the
    /// surface — `ConnectFailurePlan` omits the button entirely without a
    /// remedy — and stays because the published remedy is cleared at the
    /// head of the next attempt, which another window can start.
    func convertFailedKey(_ tab: SessionTab) {
        guard case .convertKey(let path)? = tab.connectionViewModel.lastFailureRemedy else {
            return
        }
        // A question the last conversion left unasked must not open when
        // this one's sheet closes (Task 2 fix round 1).
        setRepointRequest = nil
        setRepointDialogArmed = false
        convertKeyTarget = ImportKeyTarget(fileURL: URL(fileURLWithPath: path), tab: tab)
    }

    /// The failed-connect surface's "Copy command" (PEM private keys plan,
    /// Task 4): the in-place conversion the person runs themselves, on the
    /// pasteboard.
    ///
    /// The command line comes from `SSHKeyConverter.inPlaceCommandLine`,
    /// which quotes the path — it is not a display string and has no catalog
    /// key, the same standing `ShellCompletionRecipe`'s lines have. It never
    /// reaches a `Text`, which is what keeps the surface's "fixed catalog
    /// keys only" claim true (`ConnectFailureContent`'s own doc comment, and
    /// `theFailedSurfaceRendersNoStringOfItsOwn`).
    func copyConversionCommand(for tab: SessionTab) {
        guard case .convertKey(let path)? = tab.connectionViewModel.lastFailureRemedy else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            SSHKeyConverter.inPlaceCommandLine(forKeyAt: path), forType: .string)
    }

    /// What happens once the conversion sheet has written the new managed
    /// key (PEM private keys plan, Task 4): the session points at the
    /// converted file, and the tab dials again.
    ///
    /// Three paths, and each ends in the function that already owns its part:
    ///
    /// * A STORED session THAT OWNS ITS OWN LOGIN gets the new path written
    ///   into it through `sessionListViewModel.updateSession(_:newSecret:)`,
    ///   with `newSecret: nil` — this path replaces no secret. If the managed
    ///   key's OWN Keychain slot holds a passphrase, and no session-mode jump
    ///   references this session (`sessionServesAJumpHop(_:)`), the project's rule is
    ///   that a session using such a key carries no copy of its own
    ///   (`SessionSecretPolicy.usesStoredManagedPassphrase`): the session's
    ///   slot is dropped, because `ManagedKeyPassphrase.resolve` answers the
    ///   TYPED value first and the connect-time fill types the session's slot
    ///   into the form — a leftover copy would shadow the key's real one on
    ///   every later dial. Then `retryConnect(_:)`, the one function that
    ///   redials through the shared `connect(in:stored:)`: TOFU stays the
    ///   hard stop it is, and this surface still adds no second dial site.
    /// * A stored session bound to a LOGIN SET is ASKED (maintainer decision
    ///   1 of 2026-09-16): `LoginSetRepointPlan.request` builds the question
    ///   — the set and the converted key; how many sessions depend on the
    ///   set is read fresh when the dialog draws, not captured here
    ///   (technical follow-ups of 2026-09-18, Task 7) — and
    ///   `setRepointRequest` presents it. "Update login set" is
    ///   `repointLoginSet(_:)`; "This attempt only", the cancel button Escape
    ///   presses, is `convertForThisAttemptOnly(_:keyPath:)`. A set the question does
    ///   not apply to (gone, or not an SSH private-key set) takes the
    ///   attempt-only route straight away.
    /// * An AD-HOC attempt has nothing stored to write to and nothing stored
    ///   to redial, so it takes `convertForThisAttemptOnly(_:keyPath:)`: the
    ///   new path goes onto the form, and the tab goes back to it with the
    ///   key already selected. No retry, deliberately — the failed surface
    ///   offers an ad-hoc attempt none (`ConnectFailurePlan`'s own rule),
    ///   and this does not add one.
    ///
    /// The import sheet's `keptPassphrase` flag is deliberately NOT what
    /// decides the drop (fix round 2, review finding MEDIUM 1). It starts
    /// `true` and is only cleared when a Keychain SAVE throws, so an import
    /// with an empty passphrase reports `true` having written no slot at all
    /// — and the drop would then delete the session's own, and only, copy.
    /// The question this function asks is the one that matters,
    /// `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`:
    /// does the key's slot HOLD a passphrase. The flag stays what it is for
    /// the consumer it was written for — `SSHKeysSheet.reportKeyOutcome(
    /// keptPassphrase:)`, which warns that a passphrase the user typed did
    /// not reach the Keychain — so this handler takes it no longer.
    ///
    /// A key whose `fileName` does not address a file inside the key
    /// directory yields no path and nothing happens, which is the same
    /// refusal `ConnectionFormView.managedKeyPath(for:)` makes.
    func convertedKeyImported(_ key: ManagedKey, for tab: SessionTab) {
        // The window's injected store, not one built here (fix round 1,
        // review finding I2): `ContentView.init` takes `managedKeyStore` for
        // exactly this, and a store constructed at the call site reaches the
        // real key directory whatever a test points the window at. The same
        // instance the sheet was handed, so the path is resolved in the store
        // the key was just written into.
        guard let path = managedKeyStore.privateKeyURL(for: key)?.path(percentEncoded: false)
        else { return }
        // `loginSetID == nil` belongs in the CONDITION, not in a branch
        // inside it (fix round 2, review finding MEDIUM 2). A session bound
        // to a login set does not own the two things this branch writes:
        // `fillForm(_:from:)` resolves username, auth kind, key path and —
        // for private-key auth — the passphrase from the SET
        // (`LoginResolver.resolve` returns `SSHFieldSchema.values(from:)`
        // plus the set's own Keychain slot, and
        // `ConnectionViewModel.applyResolvedCredentials` blanks the whole
        // credential block before merging them over the session's values).
        // So `updated.ssh?.keyPath` would persist a path no dial reads, and
        // `dropSessionSecret(for:)` would delete a slot that is not the one
        // shadowing the managed key's. What such a session needs re-pointed
        // is the SET, which every session using it shares — so that is asked,
        // not done, in the `else if` below.
        let stored = failedConnectTarget(for: tab)
        if var updated = stored, updated.loginSetID == nil {
            updated.ssh?.keyPath = path
            sessionListViewModel.updateSession(updated, newSecret: nil)
            // One passphrase, one slot — and the fact that decides it is
            // whether the managed key's slot HOLDS one, asked here rather
            // than taken from the import sheet's report (fix round 2, review
            // finding MEDIUM 1; the doc comment above says what that report
            // does and does not mean). With the key holding it, the session's
            // own copy is stale AND authoritative (the fill types it in, and
            // `ManagedKeyPassphrase.resolve` prefers what is typed), so it
            // goes.
            //
            // `try?` collapses "no slot" and "could not find out" onto the
            // same answer deliberately, and in the SAFE direction: the probe
            // throws when the store or the Keychain cannot be read at all
            // (see its own doc comment), and a drop taken on an unanswerable
            // probe would destroy a secret that has no other home. A stale
            // second copy is a wrong dial the user can fix; a deleted only
            // copy is not.
            let keySlotHoldsThePassphrase = (try? ManagedKeyPassphrase.hasStoredPassphrase(
                keyPath: path, store: managedKeyStore, secrets: secretStore)) == true
            // The slot stays while a session-mode jump references this session
            // (Task 2 fix round 1) — defence in depth since the jump fills
            // take the managed key's passphrase whenever the store has one,
            // and read this slot only when it has none
            // (`SessionListViewModel.setServesAJumpHop(_:)` says why).
            let jumpHopReadsTheSessionSlot = sessionListViewModel.sessionServesAJumpHop(updated.id)
            if keySlotHoldsThePassphrase && !jumpHopReadsTheSessionSlot {
                sessionListViewModel.dropSessionSecret(for: updated.id)
            }
            retryConnect(tab)
        } else if stored != nil {
            // The request carries the set only by `id` (technical
            // follow-ups of 2026-09-18, Task 7): the dialog's message reads
            // `sessionListViewModel.dependentSessionCount(of:)` itself, at
            // render time, so it names the number of sessions that depend on
            // the set WHEN THE QUESTION IS SHOWN — directly or through a
            // jump hop — not the number captured here when the conversion
            // finished, which a session added or removed meanwhile would
            // make stale before the user ever answers.
            if let request = LoginSetRepointPlan.request(
                session: stored, sets: sessionListViewModel.loginSets,
                key: key, keyPath: path, tab: tab)
            {
                setRepointRequest = request
            } else {
                convertForThisAttemptOnly(tab, keyPath: path)
            }
        } else {
            convertForThisAttemptOnly(tab, keyPath: path)
        }
    }

    /// "Update login set" (maintainer decisions of 2026-09-16, Task 2): the
    /// set the failed attempt resolved its login from is re-pointed at the
    /// converted managed key, for every session that uses it, and the tab
    /// dials again.
    ///
    /// Three steps, each through the function that already owns it:
    ///
    /// * `saveLoginSet(_:secret:)` with a nil secret writes the new key path
    ///   and leaves the set's Keychain slot as it is. When it answers `false`
    ///   nothing below runs — no drop, no redial (technical backlog of
    ///   2026-09-16, Task 5) — and the tab stays on the failed surface.
    /// * The set's slot is then dropped if — and only if — the managed key's
    ///   own slot HOLDS the passphrase AND no jump hop resolves from the set
    ///   (`setServesAJumpHop(_:)`). That is decision 2 of 2026-09-16
    ///   carried over from sessions to sets: one passphrase, one place. The
    ///   connect-time fill types the set's slot into the form
    ///   (`LoginResolver.resolve`) and `ManagedKeyPassphrase.resolve` answers
    ///   the typed value first, so a leftover copy would shadow the key's.
    ///   With the slot gone the typed value is empty and the key's own slot
    ///   answers. `try?` collapses "no" and "could not find out" onto KEEP,
    ///   for the reason `convertedKeyImported(_:for:)` gives: a stale copy is
    ///   a wrong dial the user can fix, a deleted only copy is not.
    /// * `retryConnect(_:)` redials through the shared `connect(in:stored:)`,
    ///   which re-reads the set from `sessionListViewModel` — so the dial uses
    ///   the path just saved, TOFU stays the hard stop it is, and this adds no
    ///   dial site.
    ///
    /// The set written is the set as it stands NOW, re-read by id
    /// (`LoginSetRepointPlan.currentSet`), with only its key path changed: the
    /// dialog can stay open while another window edits the set, and saving
    /// the copy captured with the request would undo that edit. A set deleted
    /// meanwhile, or no longer an SSH private-key set, is not written at all —
    /// the conversion then applies to this attempt only. The tab is the
    /// request's, never the active tab (Task 2 fix round 1).
    func repointLoginSet(_ request: LoginSetRepointRequest) {
        guard var set = LoginSetRepointPlan.currentSet(
            id: request.set.id, in: sessionListViewModel.loginSets)
        else {
            convertForThisAttemptOnly(request.tab, keyPath: request.keyPath)
            return
        }
        set.keyPath = request.keyPath
        // A set whose new key path was not written keeps its slot and is not
        // redialled: the redial would fail against the old PEM path again, and
        // the view model's `errorMessage` already says why the save failed.
        guard sessionListViewModel.saveLoginSet(set, secret: nil) else { return }
        let keySlotHoldsThePassphrase = (try? ManagedKeyPassphrase.hasStoredPassphrase(
            keyPath: request.keyPath, store: managedKeyStore, secrets: secretStore)) == true
        // The set's slot stays while a jump hop resolves from the set (Task 2
        // fix round 1) — defence in depth since the jump fills take the
        // managed key's passphrase whenever the store has one, and read the
        // set's slot only when it has none
        // (`SessionListViewModel.setServesAJumpHop(_:)` says why).
        let jumpHopReadsTheSetSlot = sessionListViewModel.setServesAJumpHop(set.id)
        if keySlotHoldsThePassphrase && !jumpHopReadsTheSetSlot {
            sessionListViewModel.dropLoginSetSecret(for: set.id)
        }
        retryConnect(request.tab)
    }

    /// The conversion for this attempt only: the converted key goes onto the
    /// form and the tab goes back to it, with nothing stored changed and no
    /// dial. The route an ad-hoc attempt always takes, the answer "This
    /// attempt only" (or Escape) gives for a set-bound session
    /// (`convertedKeyImported(_:for:)` says which), and the fallback
    /// `repointLoginSet(_:)` takes when the set is gone at confirm time.
    func convertForThisAttemptOnly(_ tab: SessionTab, keyPath: String) {
        tab.connectionViewModel.keyPath = keyPath
        dismissConnectFailure(tab)
    }

    func fillForm(_ form: ConnectionViewModel, from stored: StoredSession) throws -> Bool {
        // ONE fill for every protocol (M23/T7). `kind` FIRST (M22/T8):
        // assigning it resets `values` to that backend's defaults, so a
        // fill that ran before it would be wiped by the protocol switch;
        // the explicit reset below is what covers the case where `kind`
        // does NOT change (two SSH sessions in a row) and its guarded
        // `didSet` therefore does nothing.
        //
        // `sessionValues` replaces the three per-protocol field lists --
        // and never copies `host`/`username` for an S3 or WebDAV session,
        // which is where the `"unused"` placeholder used to enter the form.
        form.kind = stored.kind
        let descriptor = BackendDescriptor.descriptor(for: stored.kind)
        // `editBaseline`, NOT `defaultValues`: this form IS `stored` -- a
        // saved session, not a new one -- so it must not inherit S3's
        // new-form region assumption (`BackendDescriptor.editBaseline`'s
        // doc comment). A session whose S3 block is missing shows EMPTY S3
        // fields and fails `firstViolation` at the first required field in
        // declaration order -- today that is the endpoint, not the region
        // -- the same as `ConnectionViewModel.beginEditing`.
        form.values = descriptor.editBaseline
        form.values.merge(descriptor.sessionValues(stored))
        // NOT a name MacSCP invents, so deliberately no
        // `SessionNameCollision.freeName` here (unlike `fillFromImported`
        // and `saveAsSession`): this form IS `stored`, and stepping aside
        // would show the user a renamed copy of the session they opened.
        form.saveName = stored.name
        form.appearance = stored.appearance ?? SessionAppearance()
        form.shouldSaveSession = false

        // Resolve what this session should actually connect with (M10b/T3):
        // its own data for a manual session, or its set's credentials --
        // a dangling `loginSetID` throws rather than silently falling
        // back (`LoginResolver`'s doc comment). Identical for all three
        // backends since M22/T9; only the SECRET field differed, which
        // `fillSecret` now names for whichever backend is active (the S3
        // branch filled `s3SecretAccessKey`, the other two `password`).
        do {
            if let resolved = try sessionListViewModel.resolvedCredentials(for: stored) {
                form.applyResolvedCredentials(resolved)
            } else if descriptor.requiresSecret(form.values) {
                // M-6: an agent login reads no keychain at all -- avoid
                // the residual lookup on this path too. `requiresSecret`
                // is false for exactly that case and true for S3/WebDAV,
                // which is what the `authKind != .agent` guard meant.
                form.fillSecret(sessionListViewModel.password(for: stored) ?? "")
            }
            // M17: if this key is a managed key with a stored
            // passphrase and none was typed, resolve it from the
            // Keychain so the user need not re-enter it. Inert outside
            // SSH: no other backend has a private-key auth choice.
            //
            // `managedKeyStore`/`secretStore` (connection-liveness plan,
            // Task 6 fix round 4, review-mandated): this call site builds
            // its own `ManagedKeyStore(directory: SessionStore
            // .defaultDirectory)`/`KeychainSecretStore()` inline until this
            // fix, unseamed and reachable through `connect(in:stored:)` —
            // the SAME call path `ConnectAttemptHandoffTests`' own stored-
            // session scenario drives — for any stored session using
            // private-key auth. Routed through the same two properties
            // `maybeCreateNewLoginSet(from:editedSession:)` and
            // `startSession`'s own `shouldSaveSession` branch already use.
            //
            // Through the form's own fill, which also records whether an
            // unreadable `managed_keys.json` hid the key, so a dial that then
            // needs a passphrase names the store (review follow-ups of
            // 2026-09-18, Task 6 fix round 1). It checks `authChoice` itself.
            form.fillManagedKeyPassphrase(store: managedKeyStore, secrets: secretStore)
            form.loginMode = stored.loginSetID != nil ? .set : .manual
            form.selectedLoginSetID = stored.loginSetID
        } catch is LoginResolveError {
            // Missing set (target, M10c/T3): do NOT connect -- show the
            // form instead, with the mismatch surfaced through its
            // existing error field (spec §2/§6). The user picks a login
            // or enters credentials. Falls back to the session's own raw
            // values so the form isn't left half-filled: the same
            // `editBaseline` + `sessionValues` merge as above, which leaves
            // every secret field blank because `editBaseline` does -- and,
            // for S3, leaves a missing region blank rather than guessed, for
            // the same reason the merge above uses `editBaseline` and not
            // `defaultValues`.
            //
            // Kept in its OWN do/catch, independent of the jump's below
            // (final review M-1): sharing one catch meant a JUMP-only
            // `.missingSet` also reset this (valid) target resolution --
            // a dangling jump set discarded a perfectly good target
            // login pick.
            form.values = descriptor.editBaseline
            form.values.merge(descriptor.sessionValues(stored))
            form.loginMode = .manual
            form.selectedLoginSetID = nil
            // A stale jump block from a DIFFERENT session's form must not
            // survive this early return (F-1 fix): the jump `do`/`catch`
            // below is never reached on this path, so apply the same
            // raw-jump fallback it would have applied. The S3 and WebDAV
            // branches this replaces returned WITHOUT it and so leaked a
            // stale jump into the form on a dangling-set stop.
            applyRawJumpFallback(form, from: stored)
            form.showFailure(message: L10n.string(
                "loginSets.missingSet",
                "The stored login for this connection was not found. Choose a login or enter credentials."))
            return false
        }

        // Jump (M10c/T3, extended M11a/T3): same resolution as above,
        // for the jump's OWN login — `resolvedJumpLogin` is `nil` only
        // when the session has no jump at all; a resolved jump fills
        // the manual-looking fields regardless of whether it came from
        // a set or the jump's own manual secret, exactly like the
        // target's resolution above. In its OWN do/catch (final review
        // M-1, see comment above): a jump-only failure must fall back on
        // the JUMP side only, leaving the target fields resolved above
        // untouched.
        //
        // Session mode (`jump.sessionID` non-nil, spec §4b) branches
        // FIRST: host/port and the login all come from the REFERENCED
        // session via `resolvedJump(for:)`, unlike the manual/set branch
        // below which only ever resolves the jump's OWN fields via
        // `resolvedJumpLogin`. Each branch keeps its OWN nested do/catch
        // (rather than one shared catch for both) so a session-mode
        // failure highlights `.jumpSession` — the only field the
        // session-mode UI actually renders — while a manual/set failure
        // keeps highlighting `.jumpHost` exactly as before this feature.
        if let jump = stored.jump {
            form.jumpEnabled = true
            if let sessionID = jump.sessionID {
                // Set BEFORE the throwing call below: on a failure the
                // form stays in session mode with this selection intact,
                // so the picker and the `.jumpSession` highlight the
                // failure attaches to are both visible — switching back
                // to manual with raw fallback values would hide the very
                // field the error is about.
                form.jumpSourceMode = .session
                form.jumpSessionID = sessionID
                do {
                    if let resolved = try sessionListViewModel.resolvedJump(for: stored) {
                        form.jumpHost = resolved.host
                        form.jumpTLSTunnel = resolved.tlsTunnel
                        form.jumpPort = String(resolved.port)
                        form.jumpUsername = resolved.login.username
                        form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolved.login.authKind)
                        form.jumpKeyPath = resolved.login.keyPath ?? ""
                        form.fillJumpPassphrase(resolved.login.secret ?? "")
                    }
                } catch LoginResolveError.missingJumpSession {
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.session.missing",
                            "The connection used as jump host no longer exists."),
                        field: .jumpSession)
                    return false
                } catch LoginResolveError.jumpChainNotSupported {
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.session.chainNotSupported",
                            "The selected jump host connects through another jump host; "
                                + "chains are not supported."),
                        field: .jumpSession)
                    return false
                } catch LoginResolveError.jumpSessionNotSSH {
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.session.notSSH",
                            "Only SSH connections can be used as a jump host."),
                        field: .jumpSession)
                    return false
                } catch is LoginResolveError {
                    // The REFERENCED session's own login set is dangling
                    // (`.missingSet`) -- same wording the login-set
                    // dangling-reference paths already use elsewhere.
                    form.showFailure(
                        message: L10n.string(
                            "loginSets.missingSet",
                            "The stored login for this connection was not found. "
                                + "Choose a login or enter credentials."),
                        field: .jumpSession)
                    return false
                }
            } else {
                form.jumpSourceMode = .manual
                form.jumpSessionID = nil
                form.jumpHost = jump.host
                form.jumpPort = String(jump.port)
                form.jumpLoginMode = jump.loginSetID != nil ? .set : .manual
                form.jumpSelectedLoginSetID = jump.loginSetID
                do {
                    if let resolvedJump = try sessionListViewModel.resolvedJumpLogin(for: stored) {
                        form.jumpUsername = resolvedJump.username
                        form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolvedJump.authKind)
                        form.jumpKeyPath = resolvedJump.keyPath ?? ""
                        form.fillJumpPassphrase(resolvedJump.secret ?? "")
                    }
                } catch LoginResolveError.jumpSetNotSSH {
                    // The jump is bound to a login set of another
                    // protocol (M28/T7). This is the only catch site the
                    // case can reach, because it is the only one that
                    // resolves a jump spec whose `sessionID` is nil: the
                    // three others —
                    // `SessionListViewModel.resolveJumpSession`,
                    // `ConnectionFormView.jumpSessionSummary` and the
                    // session-mode branch just above — all build or pass
                    // a spec carrying a `sessionID`, and
                    // `LoginResolver.resolveJump(...sessions:...)` only
                    // delegates to the throwing overload when that is
                    // nil; with a `sessionID` it resolves the REFERENCED
                    // session's own login instead, where a set of the
                    // wrong kind is `.kindMismatch`. (The remaining catch
                    // above is the TARGET's resolution, not a jump's.)
                    //
                    // Only the CATCH sites are enumerated above, not the
                    // call sites: `SessionListViewModel.exportPayload`
                    // calls the same overload with a possibly-nil
                    // `sessionID` too, but swallows the throw with `try?`
                    // and falls back to the spec's raw values, so the
                    // export writes no jump password and counts the jump
                    // under its missing-password tally (unless the spec's
                    // own key is a managed one whose slot holds the
                    // passphrase) instead of surfacing a refusal.
                    //
                    // The raw fallback is what keeps the refusal
                    // meaningful on THIS path: it clears
                    // `jumpSelectedLoginSetID` and returns the block to
                    // Manual, so a following submit does not walk
                    // `SessionListViewModel.resolveJumpLoginSet` into
                    // `fillJumpForm` and copy the very credentials this
                    // refusal is about into the form. It also blanks
                    // `jumpPassword` — the set's secret was never read.
                    // Editing such a session
                    // (`ConnectionViewModel.beginEditing`) reaches the
                    // same submit with no resolution and no fallback at
                    // all; the `kind` guard inside
                    // `SessionListViewModel.resolveJumpLoginSet` is what
                    // covers that route.
                    applyRawJumpFallback(form, from: stored)
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.set.notSSH",
                            "The jump host uses a stored login that is not an SSH login. "
                                + "Choose an SSH login for the jump host, or enter its "
                                + "user name and password here."),
                        field: .jumpHost)
                    return false
                } catch is LoginResolveError {
                    // Missing set (jump only): the target fields resolved
                    // above stay untouched — only the jump falls back to
                    // its raw manual-looking values, and `field:
                    // .jumpHost` (not the target's `.host`) highlights
                    // the right row. Shares the fallback with the target
                    // catch above (F-1 fix) so both early-return paths
                    // leave the jump block in the identical,
                    // fully-reset-or-fully-raw state.
                    applyRawJumpFallback(form, from: stored)
                    form.showFailure(
                        message: L10n.string(
                            "loginSets.missingSet",
                            "The stored login for this connection was not found. "
                                + "Choose a login or enter credentials."),
                        field: .jumpHost)
                    return false
                }
            }
        } else {
            form.clearJumpFields()
        }
        return true
    }

    /// Fills the jump block from the session's own raw JumpSpec values (no set
    /// resolution), or clears it entirely when the session has no jump. Used by
    /// three of `fillForm`'s seven early-return failure paths — the target's
    /// dangling-set stop and the two jump-LOGIN-set failures — so a stale
    /// jump block from a previous form state can never survive into a
    /// different session's connect. The four jump-SESSION failures skip it
    /// on purpose: they leave the form in session mode so the user can see
    /// which reference broke.
    ///
    /// `jumpSourceMode`/`jumpSessionID` are also reset here (F-2 fix, final
    /// review): the `if let jump` branch below fills only the manual-looking
    /// fields, so without this a stale `jumpSourceMode == .session` +
    /// `jumpSessionID` from a DIFFERENT, still-open form (e.g. an unconnected
    /// tab left in session mode with bastion X preselected) would survive
    /// into THIS session's (B's) connect: the picker would show X preselected
    /// while the manual fields hold B's raw jump values, and a subsequent
    /// Connect would silently route through X instead of B's own jump host.
    /// The `else` branch already resets both via `clearJumpFields()`.
    private func applyRawJumpFallback(_ form: ConnectionViewModel, from stored: StoredSession) {
        if let jump = stored.jump {
            form.jumpEnabled = true
            form.jumpSourceMode = .manual
            form.jumpSessionID = nil
            form.jumpHost = jump.host
            form.jumpPort = String(jump.port)
            form.jumpUsername = jump.username
            form.jumpAuthChoice = ConnectionViewModel.authChoice(for: jump.authKind)
            form.jumpKeyPath = jump.keyPath ?? ""
            form.jumpTLSTunnel = jump.tlsTunnel
            form.jumpPassword = ""
            form.jumpLoginMode = .manual
            form.jumpSelectedLoginSetID = nil
        } else {
            form.clearJumpFields()
        }
    }

    /// Sidebar "Edit…" click: prefill the form for in-place editing — in the
    /// active tab when it is unconnected, otherwise in a fresh tab (a running
    /// session is never displaced). Deliberately no auto-connect: the user
    /// reviews/changes fields, then picks Save or Save & connect.
    func editStored(_ stored: StoredSession) {
        let sourceGroupID = activeTab.overviewGroupID
        guard let tab = formTarget() else { return }
        tab.connectionViewModel.beginEditing(stored)
        // Editing takes precedence over the overview. Keep its origin on
        // the same tab so Back and Save return to the original group.
        tab.overviewGroupID = sourceGroupID
    }

    /// Import click: fill the form from the ssh-config entry — deliberately
    /// WITHOUT connecting (the import knows no secrets). Same target rule as
    /// "Edit…".
    func fillFromImported(_ host: SSHConfigHost) {
        guard let tab = formTarget() else { return }
        // Same statement "New connection" makes (session overview plan, Task
        // 2): this fills the FORM, so the detail pane stops being about a
        // stored session. The sidebar's imported row clears its own selection
        // as well; this covers the call arriving from anywhere else.
        overviewSessionID = nil
        let form = tab.connectionViewModel
        form.exitEditMode()
        form.clearPassword()
        form.host = host.hostName ?? host.alias
        form.port = String(host.port ?? 22)
        form.username = host.user ?? ""
        // The other INVENTED name, same rule as "Save as Session": the alias
        // comes out of `~/.ssh/config`, not out of the user's fingers, so it
        // steps aside from a stored session of that name rather than
        // replacing it on save. A form filled FROM a stored session is
        // where a matching name is the normal case instead — that is
        // `fillForm` and `ConnectionViewModel.beginEditing`, and both fill
        // this field straight from `stored.name`.
        form.saveName = SessionNameCollision.freeName(
            basedOn: host.alias, avoiding: sessionListViewModel.sessions)
        form.shouldSaveSession = false
        if let identityFile = host.identityFile {
            form.authChoice = .privateKey
            form.keyPath = identityFile
        } else {
            form.authChoice = .password
            form.keyPath = ""
        }
    }

    /// Recomputes `importedHosts` (the sidebar's VISIBLE list) and
    /// `hiddenImportAliases` from `fullImportedHosts` and a fresh
    /// `HiddenImportStore` read (M11f/T2). Called once at startup (right
    /// after `fullImportedHosts` is populated in `.task`) and again after
    /// every hide/unhide — deliberately WITHOUT re-parsing
    /// `~/.ssh/config`, since hiding/unhiding never changes what is
    /// actually in that file. A store read failure (rare: e.g. a corrupt
    /// `hidden-imports.json`) reports `hiddenImportsErrorMessage` rather than
    /// failing silently (M11f/T2 review, finding 2) — a corrupted store would
    /// otherwise resurface every hidden host AND drop the Sessions-menu count
    /// with no indication anything went wrong. Success clears the message,
    /// matching `SessionSidebar.jumpRestoreErrorMessage`'s established pattern.
    ///
    /// On a read failure the visible list falls back to the FULL set rather
    /// than to whatever it held before (M11f/T2 re-review): hiding is a
    /// cosmetic display filter, so it must never subtract from a host list
    /// that WAS read successfully on the strength of preference data that
    /// was not. Keeping the previous list would strand the user at startup,
    /// where `importedHosts` is still empty when this first runs — the whole
    /// IMPORTED section would vanish on every launch, and the sheet (which
    /// re-reads the same broken file) offers no way back. `hiddenImportAliases`
    /// is deliberately left alone: a stale count keeps the menu entry
    /// discoverable, which is where the user goes to investigate.
    func refreshImportedHosts() {
        do {
            let aliases = try HiddenImportStore(directory: SessionStore.defaultDirectory).allHidden()
            hiddenImportAliases = aliases
            importedHosts = ImportedHostPartition.split(hosts: fullImportedHosts, hiddenAliases: aliases).visible
            hiddenImportsErrorMessage = nil
        } catch {
            importedHosts = fullImportedHosts
            hiddenImportsErrorMessage = String(
                format: L10n.string(
                    "sidebar.hiddenImports.error %1$@ %2$@",
                    "Could not update hidden imports: %1$@ — you can delete %2$@ to reset the list."),
                String(describing: error),
                HiddenImportStore(directory: SessionStore.defaultDirectory).fileURL.path(percentEncoded: false))
        }
    }

    /// Sidebar imported-row context menu "Hide" (M11f/T2, spec: no
    /// confirmation dialog — this reports FAILURE only, never a success
    /// confirmation). A rare disk-write failure previously just left the
    /// row visible for another try with zero feedback (M11f/T2 review,
    /// finding 1); now it is captured separately, `refreshImportedHosts()`
    /// still runs unconditionally (the read usually still works even when
    /// the write just failed), and the write error is re-applied AFTER —
    /// same "capture separately, reload, reapply after" pattern as
    /// `HiddenImportsSheet.unhide`, so a successful `refreshImportedHosts()`
    /// read can't silently swallow this call's own write failure.
    func hideImported(_ host: SSHConfigHost) {
        var hideError: String?
        do {
            try HiddenImportStore(directory: SessionStore.defaultDirectory).hide(host.alias)
        } catch {
            hideError = String(
                format: L10n.string(
                    "sidebar.hiddenImports.error %1$@ %2$@",
                    "Could not update hidden imports: %1$@ — you can delete %2$@ to reset the list."),
                String(describing: error),
                HiddenImportStore(directory: SessionStore.defaultDirectory).fileURL.path(percentEncoded: false))
        }
        refreshImportedHosts()
        if let hideError {
            hiddenImportsErrorMessage = hideError
        }
    }

    /// Sidebar `hiddenImportsErrorBanner`'s close button and its own
    /// six-second auto-dismiss (dev-build follow-up, 2026-09-03) — the
    /// third red caption, left open by `ece5aaf9`, which gave the other two
    /// (`viewModel.errorMessage` via `SessionListViewModel.dismissError()`,
    /// and the sidebar's own local `jumpRestoreErrorMessage`) this same
    /// treatment. `hiddenImportsErrorMessage` reaches `SessionSidebar` as a
    /// plain `let`, so the clear has to happen here, on the property that
    /// actually owns it — the same one `refreshImportedHosts()`'s success
    /// path already sets to `nil`. Does not touch anything else a later
    /// `hideImported`/`refreshImportedHosts` call sets; a later failure
    /// still shows again, because nothing here latches the channel shut.
    func dismissHiddenImportsError() {
        hiddenImportsErrorMessage = nil
    }

    /// Sidebar "New connection": blank the active tab's form when it is
    /// unconnected (M6a — without this, host/username/name from a previous
    /// edit stay prefilled), otherwise open a fresh empty tab. The toolbar
    /// "Disconnect" deliberately keeps the fields (reconnect convenience) —
    /// only this path blanks them.
    func newConnection() {
        let tab = activeTab
        tab.overviewGroupID = nil
        tab.isNewConnectionFormDismissed = false
        if tab.isConnected {
            showNewConnectionTab()
            return
        }
        guard !tab.isReconnecting else { return }
        // A tab sitting on the lost-connection surface is "unconnected" by
        // `isConnected`, so this path reuses it — but the surface, not the
        // form, is what `ConnectionSurfacePlan` puts on screen for it
        // (connection-liveness plan, Task 7). Without this the fields would
        // be blanked behind an error view and the command would look like
        // it did nothing.
        dismissLostConnection(tab)
        // Same argument for the failed-connect surface (failed-connect
        // surface plan, Task 3): a tab showing it is "unconnected" too, so
        // without this the blanked fields would sit behind an error view
        // and the command would look like it did nothing.
        dismissConnectFailure(tab)
        tab.connectionViewModel.endEditing()
        // The user asked for an empty form (session overview plan, Task 2).
        // Verified 2026-09-04 (final fix round, item 4): this function has
        // exactly one caller, `ContentView+Detail.swift:77`'s `onNew:`,
        // reached only from `SessionSidebar.startNewConnection()` — which
        // already clears the sidebar's own selection via
        // `onSelectSession(nil)` immediately before calling this. ⌘N is
        // bound to "New Tab" (`MacSCPApp.swift`, `tabCommands.newTab`), a
        // different function entirely, and no Sessions-menu entry reaches
        // this one either. The clear stays here anyway: this function does
        // not lean on its one caller having already arranged it, so "asking
        // for a new connection blanks the overview" stays true on its own
        // rather than on trust that every future caller repeats the
        // sidebar's own clearing step.
        overviewSessionID = nil
    }

    /// Target tab for the form-filling actions ("Edit…", ssh-config import,
    /// and the tab menu's "Save as Session…", which lives in
    /// `ContentView+Lifecycle.swift` and is why this is no longer
    /// `private`): the active tab if it is unconnected and idle, otherwise a
    /// new tab. `nil` while the active tab is mid-connect (the click is
    /// ignored, as it is today).
    func formTarget() -> SessionTab? {
        let tab = activeTab
        tab.isNewConnectionFormDismissed = false
        if tab.isConnected {
            let fresh = makeTab()
            addTabRegistering(fresh)
            return fresh
        }
        guard !tab.isReconnecting else { return nil }
        tab.overviewGroupID = nil
        // Same reason as `newConnection()` above (connection-liveness plan,
        // Task 7): every caller of this fills the FORM, which a tab still
        // showing the lost-connection surface would not be displaying.
        dismissLostConnection(tab)
        // And past the failed-connect surface (failed-connect surface plan,
        // Task 3), for the identical reason.
        dismissConnectFailure(tab)
        return tab
    }

    /// Toolbar "Disconnect": tears this tab's session down and returns it to
    /// the form. The tab's queue survives — interrupted transfers stay
    /// resumable after a reconnect, exactly as before.
    @discardableResult
    func disconnectToForm(_ tab: SessionTab) -> Task<Void, Never>? {
        guard !tab.isReconnecting else { return nil }
        tab.isReconnecting = true // synchronous — prevents double teardown (would corrupt lastBrowserSize)
        return Task {
            defer { tab.isReconnecting = false }
            await teardown(tab, reason: .userRequested)
        }
    }

    /// Snapshot this window before suspending. Cancel pending dials so they
    /// cannot attach a new connection after the global Stop command.
    func stopAllWindowConnections() async {
        let tabs = tabsModel.tabs
        for tab in tabs where !tab.isConnected && (tab.isReconnecting
            || tab.connectionViewModel.state == .connecting || tab.lostConnection != nil) {
            tab.reconnectAttempt = UUID()
            tab.connectionViewModel.cancelConnecting()
            tab.isReconnecting = false
            tab.lostConnection = nil
            tab.liveness = nil
        }
        let stops = tabs.filter(\.isConnected).compactMap { disconnectToForm($0) }
        for task in stops { await task.value }
    }

    func presentTerminalUnavailable(_ message: String? = nil) {
        terminalUnavailableAlertMessage = message ?? L10n.string(
            "shortcut.unavailableForProtocol",
            "This shortcut isn't available for this connection type.")
    }

    // MARK: - External terminal (M11d/T2)

    /// Restore credentials only for the endpoint actually connected in this
    /// tab. Never retain secrets in `lastConnectedConfig` or launch an edited
    /// saved profile's different endpoint accidentally.
    func requestExternalTerminal(for tab: SessionTab) {
        // No session, or somehow no resolved config for one (never happens
        // in practice — a connected tab always has one, set by
        // `ConnectionViewModel.connect()` on success): nothing to open.
        guard tab.isConnected, let config = tab.connectionViewModel.lastConnectedConfig else { return }
        if case .resolved(.ssh(let candidate)) = tab.connectionViewModel.resolveConfigWithoutDialing(),
           candidate.redactingSecrets() == config.redactingSecrets() {
            requestExternalTerminal(config: candidate)
            return
        }
        if let id = tab.activeStoredSessionID,
           let stored = sessionListViewModel.sessions.first(where: { $0.id == id }) {
            let form = ConnectionViewModel(connector: { _, _ in
                throw RemoteFSError.connectionFailed(reason: "Credential resolution never dials")
            })
            do {
                if try fillForm(form, from: stored),
                   case .resolved(.ssh(let candidate)) = form.resolveConfigWithoutDialing(),
                   candidate.redactingSecrets() == config.redactingSecrets() {
                    requestExternalTerminal(config: candidate)
                    return
                }
            } catch {
                externalTerminalErrorMessage = error.localizedDescription
                return
            }
        }
        requestExternalTerminal(config: config)
    }

    /// Sidebar row "Open in External Terminal" (P3c/T2): resolves what this
    /// session WOULD connect with and hands it to the external terminal.
    /// MacSCP itself does not connect, opens no tab, and touches no other
    /// tab's form.
    ///
    /// The form is a throwaway, built here and gone when this method
    /// returns. Two reasons it is not a tab's form: filling a visible form
    /// would overwrite whatever the user has typed into the unconnected tab
    /// on screen, and — the reason that matters more — the resolved config
    /// carries a plaintext secret. Retained endpoint metadata uses
    /// `redactingSecrets()`; only the bounded launch exchange owns credentials
    /// briefly and clears them explicitly.
    /// Its connector throws rather than dialling: the one path that could
    /// turn this into a connection is closed structurally, not by
    /// convention. Nothing here calls it.
    ///
    /// Both refusals — the fill's (a dangling login set, a jump that no
    /// longer resolves) and the resolution's (a missing secret, a jump the
    /// config rejects) — are shown, in the same alert an
    /// `ExternalTerminalLauncher.LaunchError` uses. They have to be shown
    /// HERE: `resolveConfigWithoutDialing` publishes nothing by design
    /// (P3c/T1), and the throwaway form the fill publishes onto is on no
    /// screen, so an ignored failure would be a silent no-op.
    func openExternalTerminalFromSidebar(_ stored: StoredSession) {
        let form = ConnectionViewModel(connector: { _, _ in
            throw RemoteFSError.connectionFailed(
                reason: "the external-terminal route resolves a configuration and never dials it")
        })
        do {
            guard try fillForm(form, from: stored) else {
                presentExternalTerminalFailure(form.state)
                return
            }
        } catch {
            externalTerminalErrorMessage = error.localizedDescription
            return
        }
        switch form.resolveConfigWithoutDialing() {
        case .failed(let failure):
            presentExternalTerminalFailure(failure)
        case .resolved(let config):
            // Defensive: the entry is hidden for every backend without a
            // shell (`SessionRowTerminalMenuPlan`), and SSH is the only one
            // that has one, so a non-SSH config cannot arrive here.
            guard case .ssh(let ssh) = config else { return }
            requestExternalTerminal(config: ssh)
        }
    }

    /// Puts a `ConnectionViewModel.State` that refused into the external
    /// terminal's own error alert (P3c/T2) — the same surface a launch
    /// failure uses, so the sidebar route has no failure display of its own.
    ///
    /// The `field:` such a state carries is dropped on purpose: it names a
    /// row of a connection form, and this route has none on screen. Only the
    /// message is shown, and a message never contains a secret (Core builds
    /// them from `CoreL10n` keys). A state that is not `.failed` cannot
    /// reach here, and would show nothing if it did.
    private func presentExternalTerminalFailure(_ state: ConnectionViewModel.State) {
        guard case .failed(let message, _) = state else { return }
        externalTerminalErrorMessage = message
    }

    /// Hand credentials directly to the bounded in-memory askpass exchange,
    /// not to retained SwiftUI state or a command file.
    func requestExternalTerminal(config: SSHConnectionConfig) {
        let customPath = settingsStore.customTerminalAppPath
        let target = settingsStore.terminalTarget

        Task {
            await performExternalOpen(config: config, target: target, customPath: customPath)
        }
    }

    /// Writes and launches the disposable script via `ExternalTerminalLauncher`;
    /// any `LaunchError` becomes a concrete alert message (spec §4 item 7) —
    /// never a silent failure or a fallback to a different app. `async`
    /// because `ExternalTerminalLauncher.open` now awaits `NSWorkspace`'s
    /// own launch completion (review finding I-2) instead of firing it with
    /// `completionHandler: nil`; callers wrap this in `Task { }`.
    private func performExternalOpen(config: SSHConnectionConfig, target: TerminalTarget, customPath: String?) async {
        do {
            try await ExternalTerminalLauncher.open(config: config, target: target, customPath: customPath)
        } catch ExternalTerminalLauncher.LaunchError.applicationNotFound(let name) {
            externalTerminalErrorMessage = String(
                format: L10n.string("externalTerminal.error.applicationNotFound %@", "Couldn't find \u{201C}%@\u{201D}."),
                name)
        } catch ExternalTerminalLauncher.LaunchError.noCustomAppChosen {
            externalTerminalErrorMessage = L10n.string(
                "externalTerminal.error.noCustomAppChosen", "No app has been chosen yet.")
        } catch ExternalTerminalLauncher.LaunchError.scriptWriteFailed(let reason) {
            externalTerminalErrorMessage = String(
                format: L10n.string(
                    "externalTerminal.error.scriptWriteFailed %@", "Couldn't write the launch script: %@"),
                reason)
        } catch ExternalTerminalLauncher.LaunchError.launchFailed(let reason) {
            externalTerminalErrorMessage = String(
                format: L10n.string("externalTerminal.error.launchFailed %@", "Couldn't launch the app: %@"),
                reason)
        } catch {
            externalTerminalErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Notifications (next build of 2026-09-17, Task 7)

extension ContentView {
    /// Every tab's count of transfer failures that were not a drop's sweep,
    /// in tab order — the `Equatable` value `body`'s `.onChange` watches to
    /// run `notifyTransferFailures()`. A typed property rather than an
    /// inline `.map`, for the same type-checker reason `tabIDs` is one.
    var transferFailureCounts: [Int] {
        tabsModel.tabs.map(\.transferQueue.failureCountExcludingConnectionLoss)
    }

    /// Whether this window is the key window, for the notification rule
    /// only (`ErrorNotificationPlan.shouldPost`): a notification about a tab
    /// in the window the user is typing into is one they are already
    /// looking at. It decides nothing about which window a menu acts on —
    /// that is the focused value's job, and `TabsWindowLifecycleTests
    /// .nothingReAsksWhichWindowIsKey` keeps key-window reads out of the
    /// files that route menus.
    var notificationWindowIsKey: Bool {
        window?.isKeyWindow ?? false
    }

    /// The name a notification may carry for a tab: its stored session's
    /// name, or `nil` for a connection that is not a stored session. Never
    /// the tab's title, which for an unsaved connection spells the user and
    /// the host.
    func notificationName(forStoredSession id: UUID?) -> String? {
        guard let id else { return nil }
        return sessionListViewModel.sessions.first { $0.id == id }?.name
    }

    /// Posts a "transfer failed" notification for a tab whose queue has
    /// failed since the last check — at most one per tab until this window
    /// next becomes key (`TransferFailureLatch`, fix round 1). Every check
    /// answers for the failures it saw whether or not anything was posted:
    /// a failure seen while the setting was off, while the window was key,
    /// or while the latch held is not posted later.
    ///
    /// Reads `failureCountExcludingConnectionLoss`, not `totalFailureCount`:
    /// the items a drop marks failed are the drop's, and
    /// `handleLivenessGiveUp(_:)` notifies about the drop. A cancelled item
    /// is `.cancelled` and counts in neither
    /// (`TransferQueueViewModel.cancel(itemID:)`, `cancelAll(reason:
    /// .userRequested)`, a conflict prompt dismissed).
    ///
    /// **One drop can still raise two notifications, and that is ruled
    /// deliberate** (deferred minor of 2026-09-17, decided 2026-09-27). The
    /// count above leaves out the items a SWEEP marked — `cancelAll(reason:
    /// .connectionLost)`'s — and nothing else, so a transfer that fails on
    /// its own lost connection, through a foreign error no backend wrapped,
    /// is `.failed(.connectionLost)` and does count
    /// (`TransferQueueViewModelTests
    /// .aTransfersOwnLostConnectionCountsAsATransferFailure`). It raises
    /// "transfer failed" here, and "connection lost" follows later from the
    /// one site that posts it, `handleLivenessGiveUp(_:)`.
    ///
    /// De-duplicating the two would be wrong, because the second one is not
    /// guaranteed to come at all:
    ///
    /// - For non-TLS routes, `LivenessProbeRunner` probes only while
    ///   `keepAliveEnabled` is on. With it off nothing gives up,
    ///   and suppressing the notification here would tell the user nothing
    ///   whatsoever about a transfer that died.
    /// - On non-TLS routes, `LivenessProbePolicy.decide` answers `.skip`
    ///   while the queue is busy, so the give-up cannot happen until the
    ///   queue goes quiet — long after the transfer failed.
    /// - And one failed request is not a dropped session: the next probe
    ///   may well succeed, which leaves "transfer failed" the only true
    ///   thing anyone was told.
    ///
    /// The cost is bounded rather than open-ended: `TransferFailureLatch`
    /// allows at most one "transfer failed" per tab until that tab's window
    /// is key again, so the worst case for one drop is two banners, not a
    /// burst.
    func notifyTransferFailures() {
        for tab in tabsModel.tabs {
            guard tab.transferFailureLatch.takeFailures(
                count: tab.transferQueue.failureCountExcludingConnectionLoss)
            else { continue }
            let posted = errorNotifier.notify(
                .transferFailed,
                name: notificationName(forStoredSession: tab.activeStoredSessionID),
                enabled: settingsStore.notificationsEnabled,
                windowIsKey: notificationWindowIsKey)
            if posted { tab.transferFailureLatch.notificationPosted() }
        }
    }

    /// This window became key: the user has seen its tabs, so each tab's
    /// "transfer failed" latch is released (fix round 1). Called from the
    /// `controlActiveState` observer in `body`.
    func transferNotificationWindowBecameKey() {
        for tab in tabsModel.tabs {
            tab.transferFailureLatch.windowBecameKey()
        }
    }
}
