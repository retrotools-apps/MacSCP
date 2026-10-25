import AppKit
// Only for `NotificationCenter.publisher(for:)` inside `windowChrome(_:)`
// below — the app observes exactly one AppKit notification
// (`NSWindow.willCloseNotification`, to tell the Settings window that this
// window is gone).
import Combine
import SwiftUI
import macSCPCore

/// Detail-pane builders split out of `ContentView.swift`: the two-pane
/// split layout, the window-chrome modifier group, the composed
/// `mainContent`, the tab-identity proxy that drives its `.onChange`, the
/// connected/prompt/form detail view, and the terminal panel it embeds.
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    /// The window's two-pane layout: session sidebar on the left, tab strip
    /// plus detail on the right.
    ///
    /// Split out of `mainContent` (M20 CI fix) so the layout and the modifier
    /// chain that decorates it are two separate inference problems instead of
    /// one. Together they had grown past what the type checker will solve.
    ///
    /// Also mounts one `LivenessProbeRunner` per tab `LivenessProbeCoverage
    /// .tabsToProbe` selects (connection-liveness plan, Task 4, fix rounds
    /// 1 through 3) — deliberately here and not inside `detail`, which
    /// SwiftUI mounts only for the active tab; see `LivenessProbeRunner`'s
    /// own doc comment for why a background tab needs its probe running
    /// too, and `LivenessProbeCoverage`'s own doc comment for why WHICH
    /// tabs get probed is a question answered by that type, not decided
    /// inline here.
    var splitLayout: some View {
    HSplitView {
        if isSidebarVisible || showsSettingsWorkspace {
        ZStack {
            SettingsSidebarView(selection: $settingsSection,
                onSessions: { showsSettingsWorkspace = false; showsTunnelWorkspace = false },
                onTunnels: { showsSettingsWorkspace = false; showsTunnelWorkspace = true })
                .opacity(showsSettingsWorkspace ? 1 : 0)
                .allowsHitTesting(showsSettingsWorkspace)
                .disabled(!showsSettingsWorkspace)
                .accessibilityHidden(!showsSettingsWorkspace)
            TunnelWorkspaceSidebar(manager: TunnelManager.shared, selection: $tunnelWorkspaceSelection,
                                   decider: tunnelHostKeyDecider, onSessions: { showsTunnelWorkspace = false },
                                   onSettings: { showsSettingsWorkspace = true },
                                   onNewTunnel: { requestsNewTunnel = true })
                .opacity(showsTunnelWorkspace && !showsSettingsWorkspace ? 1 : 0)
                .allowsHitTesting(showsTunnelWorkspace && !showsSettingsWorkspace)
                .disabled(!showsTunnelWorkspace || showsSettingsWorkspace)
                .accessibilityHidden(!showsTunnelWorkspace || showsSettingsWorkspace)
        SessionSidebar(
            viewModel: sessionListViewModel,
            activeSessionID: activeTab.activeStoredSessionID,
            connectedSessionIDs: SessionSidebarConnections.connectedSessionIDs(in: tabsModel.tabs),
            // A running transfer no longer locks the sidebar (M8a): a
            // sidebar connect opens a NEW tab instead of tearing the
            // connected one down. Editing a saved session, or the active
            // tab's own in-flight connect/reconnect, blocks navigation.
            interactionsDisabled: sidebarInteractionsDisabled,
            // The sidebar's whole ability to reach a host, as three values
            // it can hold and hand on but not fire: `apply`, the only code
            // that runs one, is `fileprivate` to the file declaring the
            // effect types, and the sidebar's own way in states an input
            // instead of picking an activation. See
            // `SessionRowConnectEffect` for what that does and does not
            // buy. The two terminal effects sit beside the entries they
            // belong to rather than here.
            onConnect: SessionRowConnectEffect { stored in connectFromSidebar(stored) },
            onDelete: { stored in
                // Return value (M11a/T3): the sidebar surfaces
                // `secretFailures` as its own red inline message, the
                // same way `LoginSetsSheet.deleteSelected()` does for
                // `deleteLoginSet`.
                let result = sessionListViewModel.delete(stored)
                for tab in tabsModel.tabs where tab.activeStoredSessionID == stored.id {
                    tab.activeStoredSessionID = nil
                    // Same release as `teardown`'s audit recorder block
                    // (M9b/T4 review, finding 1): leaving `auditRecorder`
                    // and its two sinks wired after the STORE's log file
                    // was just deleted means the next event (teardown's
                    // own `recordDisconnected()` is guaranteed to fire
                    // later) recreates `audit/<id>.json` from scratch —
                    // an unreachable, permanent orphan, since no session
                    // list entry (and no sidebar menu) points at that id
                    // anymore.
                    tab.auditRecorder = nil
                    tab.transferQueue.auditSink = nil
                    tab.session?.remote.auditSink = nil
                }
                return result
            },
            onNew: { newConnection() },
            // The sidebar's selection, reported upward (session overview
            // plan, Task 2). The sidebar keeps owning WHERE the pointer is;
            // the window only needs to know which stored session it names,
            // because an unconnected tab shows that session's overview
            // instead of an empty form. `nil` arrives from the two "New
            // connection" entries and from an `~/.ssh/config` row.
            onSelectSession: { selected in
                activeTab.overviewGroupID = nil
                overviewSessionID = selected
                // A click on a row is the user pointing the FRONT tab
                // somewhere else, so it also ends that tab's restored
                // pointer (Detachable Tabs plan, Task 5 fix round 1).
                // Only the active tab's: the other restored tabs are not
                // what the user just pointed at, and each keeps its own.
                tabsModel.activeTab.restoredSessionID = nil
            },
            onSelectGroup: { showSessionGroup($0) },
            selectedGroupID: activeTab.overviewGroupID,
            onAllConnections: { showSessionGroup(SessionGroupCatalog.allConnections) },
            onEdit: { stored in editStored(stored) },
            // The two terminal entries (P3c/T2). "Open Terminal" is
            // `connectFromSidebar` with one argument filled in — both are a
            // single line onto `sidebarStart`, so it cannot drift from what
            // the sidebar's own connect does, including the already-open
            // query that start raises (C2); "Open in External
            // Terminal" resolves the session and launches without MacSCP
            // connecting at all — the program it launches is what dials.
            // Both are effect values for the same reason `onConnect` is: a
            // stray click reaching either one reaches the user's host.
            onOpenTerminal: SessionRowTerminalEffect { stored in openTerminalFromSidebar(stored) },
            onOpenExternalTerminal: SessionRowExternalTerminalEffect { stored in openExternalTerminalFromSidebar(stored) },
            onExport: { scope in exportSheetItem = ExportSheetItem(scope: scope) },
            onImport: { showImportFileImporter = true },
            onShowAuditLog: { stored in auditLogSession = stored },
            // The session menu's door (design §1). Works for a
            // session that is not connected — the panel opens with
            // nothing measured, and the probes run on its own button.
            onDiagnose: { stored in showDiagnostics(for: .stored(stored)) },
            // The app-wide forwardings (port-forwarding plan, Task 6).
            // `TunnelManager.shared` rather than a per-window value: a
            // forwarding belongs to no window and outlives every tab, so
            // there is no window-scoped place it could live.
            //
            // The decider handed with every START is this WINDOW's — the
            // sheet-backed `tunnelHostKeyBridge` below — the same shape the
            // session row's Connect uses, where the tab's own view model
            // wraps its prompt. Autostart hands `.refusing` instead, inside
            // the manager, and never reaches a prompt at all.
            tunnels: TunnelManager.shared,
            onStartTunnel: SessionRowStartTunnelEffect { profile in
                Task { await TunnelManager.shared.start(profile, decider: tunnelHostKeyDecider) }
            },
            onStopTunnel: { profile in Task { await TunnelManager.shared.stop(profile) } },
            onStartAllTunnels: SessionRowStartAllTunnelsEffect { stored in
                Task {
                    await TunnelManager.shared.startAll(
                        for: stored.id, decider: tunnelHostKeyDecider)
                }
            },
            onStopAllTunnels: { stored in
                Task { await TunnelManager.shared.stopAll(for: stored.id) }
            },
            onManageTunnels: { stored in tunnelProfilesSession = stored },
            onShowKnownHosts: { showKnownHostsSheet = true },
            onShowLogins: { showLoginSetsSheet = true },
            // Compact sidebar mode (sidebar-polish plan, Task 2), read here
            // as a plain presentation fact
            // about what the window offers, not a decision the sidebar
            // makes itself.
            sidebarCompact: settingsStore.sidebarCompact,
            // E1, read here rather than in the sidebar: the setting is a
            // fact about what the window offers, and the sidebar reacts to
            // the value without knowing where it comes from.
            onShowTunnels: { showsTunnelWorkspace = true },
            onShowSettings: { showsSettingsWorkspace = true }
        )
        .opacity(!showsTunnelWorkspace && !showsSettingsWorkspace ? 1 : 0)
        .allowsHitTesting(!showsTunnelWorkspace && !showsSettingsWorkspace)
        .disabled(showsTunnelWorkspace || showsSettingsWorkspace)
        .accessibilityHidden(showsTunnelWorkspace || showsSettingsWorkspace)
        }
        // Opens at the width this window was last left at and can be
        // dragged anywhere inside `SettingsStore.sidebarWidthRange` — see
        // that range for where its two ends come from. The old hardcoded
        // ceiling of 260 was the whole complaint: the divider simply
        // stopped there, and nothing about the width survived a relaunch.
        .frame(
            minWidth: CGFloat(SettingsStore.sidebarWidthRange.lowerBound),
            idealWidth: sidebarOpeningWidth,
            maxWidth: CGFloat(SettingsStore.sidebarWidthRange.upperBound))
        // Publishes the width the split view actually gave the sidebar, so
        // the recorder below sees it together with the container it sits in.
        // A background changes nothing about the sidebar's own size.
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarMeasuredWidthKey.self, value: proxy.size.width)
            }
        }

        }
        VStack(spacing: 0) {
            if showsTunnelWorkspace {
                TunnelWorkspaceView(
                    manager: TunnelManager.shared, sessions: sessionListViewModel.sessions,
                    decider: tunnelHostKeyDecider, selection: $tunnelWorkspaceSelection,
                    requestsNewTunnel: $requestsNewTunnel)
            } else {
            // Hidden in the pristine (single unconnected tab) state — a
            // strip with nothing to switch between would just be clutter
            // (M8a/T4 spec 2).
            if !isPristine { tabStrip }
            detail
            }
        }
        // Keep browser tasks, transfers and connection probes mounted under Settings.
        .opacity(showsSettingsWorkspace ? 0 : 1)
        .allowsHitTesting(!showsSettingsWorkspace)
        .disabled(showsSettingsWorkspace)
        .accessibilityHidden(showsSettingsWorkspace)
        .overlay {
            if showsSettingsWorkspace {
                SettingsWorkspaceView(store: settingsStore, 
                    launchLanguage: launchLanguage, settingsBridge: settingsPageBridge,
                    selection: $settingsSection, onClose: { showsSettingsWorkspace = false })
            }
        }
        // The detail minimum must fit inside the window minimum
        // below together with the sidebar minimum (170), otherwise
        // the split view's content overflows the window and gets
        // clipped on both sides instead of shrinking.
        .frame(minWidth: isPristine ? 500 : 590, maxWidth: .infinity)
    }
    // One probe per tab `LivenessProbeCoverage.tabsToProbe` selects (Task
    // 4, fix rounds 1 through 3) — see that type's own doc comment for why
    // the coverage decision is asked of it rather than made here. Zero-size
    // and non-hit-testing, so this changes nothing about layout or input;
    // `ForEach` drops a tab's runner (cancelling its `.task`) the instant
    // that tab leaves the selected set.
    .background {
        ForEach(LivenessProbeCoverage.tabsToProbe(from: tabsModel.tabs)) { tab in
            LivenessProbeRunner(
                tab: tab, settingsStore: settingsStore,
                onGiveUp: { await handleLivenessGiveUp($0) })
        }
    }
    // Connect-attempt liveness mirror (Task 6): one per tab, not only the
    // active one — see `ConnectAttemptLivenessMirror`'s own doc comment for
    // why. Zero-size and non-hit-testing, the same shape as the probe
    // runners above; a second `.background` layer composes with the first
    // rather than replacing it.
    .background {
        ForEach(tabsModel.tabs) { tab in
            ConnectAttemptLivenessMirror(tab: tab)
        }
    }
    // Unattended reconnect (Task 7): one per tab, for the same reason the
    // two `.background` layers above are — a tab whose connection dropped
    // while it was NOT the one on screen is the tab that most needs this.
    // Same zero-size, non-hit-testing shape; a third `.background` layer
    // composes with the two above rather than replacing either.
    .background {
        ForEach(tabsModel.tabs) { tab in
            ReconnectRunner(
                tab: tab, settingsStore: settingsStore,
                targetIsKnown: { reconnectTarget(for: $0) != nil },
                onAttempt: { reconnect($0) })
        }
    }
    .backgroundPreferenceValue(SidebarMeasuredWidthKey.self) { measuredSidebarWidth in
        GeometryReader { proxy in
            if isSidebarVisible {
            SidebarWidthRecorder(
                settingsStore: settingsStore,
                sample: SidebarWidthSample(
                    container: proxy.size.width, sidebar: measuredSidebarWidth))
            }
        }
    }
    }

    /// Window-level chrome: minimum size, tint, title, the `NSWindow` handle,
    /// and the once-per-appearance setup hook.
    /// 
    /// One of three modifier groups `mainContent` composes (M20 CI fix). Each is
    /// its own generic function so the type checker solves three small problems
    /// rather than one it gives up on.
    func windowChrome<Content: View>(_ content: Content) -> some View {
        let title: TabTitle = showsSettingsWorkspace
            ? .named(L10n.string("sidebar.settings", "Settings")) : showsTunnelWorkspace
            ? .named(L10n.string("workspace.tunnels", "Tunnels")) : tabTitle(for: activeTab)
        return content
        // Compact form vs. browser: the minimum size depends on the window's
        // pristine state (M5c/T0, M8a/T3) — replaces the global `.frame` from
        // `MacSCPApp.swift`.
        .frame(
            minWidth: isPristine
                ? MainWindowSizePlan.formSize.width : MainWindowSizePlan.browserFloor.width,
            minHeight: MainWindowSizePlan.formSize.height)
        .tint(DesignTokens.remoteBlue)
        // The active tab's title — the same answer its label in the tab
        // strip draws (`tabTitle(for:)`, jump-and-groups plan, Task 3).
        .navigationTitle(title.windowTitle)
        // Keep NSWindow's title metadata, but draw only the branded leading
        // item: macOS otherwise also inserts its default leading title item.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WindowTitleView(title: title)
            }
        }
        .background(WindowAccessor {
            let resolvedNewWindow = window !== $0
            window = $0
            $0?.tabbingMode = .disallowed
            if resolvedNewWindow { publishToMenuBarIfKey() }
            // Frame memory for the primary window only (Detachable Tabs
            // plan, Task 2 fix round 2). Through the wrapper, not the bare
            // `applyFrameAutosave(to:)`: the first resolution at launch is
            // where AppKit applies the stored frame, and it applies it on
            // `NSScreen.main` rather than on the display it was saved on —
            // see `applyFrameAutosaveKeepingItsDisplay(to:)`.
            applyFrameAutosaveKeepingItsDisplay(to: $0)
            updateMainWindowPresence()
            // "Keep on Top" (Detachable Tabs plan, Task 4): applied again
            // on every resolution, not just once — `WindowAccessor` calls
            // back on ordinary body updates too (see its own doc comment),
            // and a freshly resolved `NSWindow` has AppKit's own default
            // level until this runs, regardless of what `keepOnTop`
            // already holds.
            $0?.level = WindowLevelPlan.level(keepOnTop: keepOnTop)
        })
        // Tells the Settings window when this window goes away, so its
        // "Manage Data" entries that route HERE can disable themselves
        // instead of swallowing the click (see `updateMainWindowPresence`).
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification),
            perform: handleWindowWillClose)
        // The size a user drags the main window to is remembered across
        // launches — see `handleWindowDidEndLiveResize(_:)`.
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification),
            perform: handleWindowDidEndLiveResize)
        // The other half of a tab dragged into ANOTHER window (Detachable
        // Tabs plan, Task 3): the window it arrived in performed the move
        // and took the close decision on this window's behalf, because a
        // drop is reported only to the strip it landed on. This is how the
        // answer gets back — see `TabWindowCloseRequest`.
        .onReceive(
            NotificationCenter.default.publisher(for: TabWindowCloseRequest.notification),
            perform: handleWindowShouldCloseAfterMove)
        // Publishes THIS window's menu bridge to SwiftUI's focus system
        // (Detachable Tabs plan, Task 2 fix round 1). `MacSCPCommands` reads
        // it back with `@FocusedValue`, so the menu bar always acts on the
        // window in front — no notification observer, no key-window guard,
        // and nothing for a background window to overwrite.
        .focusedSceneValue(\.tabCommands, tabCommands)
        .focusedSceneValue(\.fileInspectionActions, fileInspectionActions)
        // Extracted wholesale into `performWindowSetup()` (M20 CI fix).
        // This closure had grown to ~125 statements in the same inference
        // scope as the `HSplitView` above, and the type checker gave up on
        // the whole `mainContent` expression -- on the CI runner first,
        // which is slower than a dev machine and hits the per-expression
        // time budget sooner. Same failure mode and same remedy as
        // `publishToMenuBarIfKey()` (M11n/T2) and `handleCloseActiveTabCommand`
        // (M14/T5); this time the whole body moves rather than one closure.
        .task { performWindowSetup() }
        // Destructive confirmation for closing a tab with active transfers
    }

    /// Composed from `splitLayout` plus three modifier groups rather than one
    /// long chain -- see `windowChrome(_:)`.
    var mainContent: some View {
        lifecycleAndToolbar(sheetsAndAlerts(windowChrome(splitLayout)))
    }

    /// See the `.onChange(of: tabIDs)` call in `ContentView+Lifecycle.swift`.
    var tabIDs: [UUID] {
        tabsModel.tabs.map(\.id)
    }

    /// The window's tab strip and every route out of it.
    ///
    /// A property of its own rather than an expression inside `body`
    /// (drag-detach fix, 2026-09-05): the detach route was the eighth
    /// argument, and with it in place the whole `body` expression stopped
    /// type-checking in reasonable time — the compiler gave up on the
    /// sidebar's `GeometryReader`, several hundred lines away, which is
    /// what a too-large expression looks like from the outside. Nothing
    /// about the wiring changed in the move.
    private var tabStrip: some View {
        TabStripView(
            tabs: tabsModel.tabs,
            activeTabID: tabsModel.activeTab.id,
            onActivate: { activate($0) },
            onClose: { requestClose($0) },
            onAdd: { showNewConnectionTab() },
            title: { tabTitle(for: $0) },
            menuEntries: { tabMenuEntries(for: $0) },
            onMenuEntry: { tab, entry in handleTabMenuEntry(entry, for: tab) },
            // A tab whose drag ended where nothing accepted it takes the
            // window's existing move path — the same one the tab context
            // menu's "Move Tab to New Window" and the Window menu already
            // call, so a detached tab is parked, opened and claimed exactly
            // once however the user asked for it.
            onDetachToNewWindow: { moveToNewWindow($0) },
            onReorder: { draggedID, target in
                tabsModel.move(tabID: draggedID, onto: target.id)
            },
            onPair: { pairDroppedTab($0, with: $1) },
            windowID: windowID,
            onDropFromOtherWindow: { acceptDroppedTab($0) }
        )
    }

    /// What `tab`'s detail pane shows while it has no session
    /// (jump-and-groups plan, Task 1): `DetailSurfacePlan.surface`'s answer,
    /// with the facts it decides on read off the tab and the window here,
    /// and nowhere else.
    ///
    /// A function of its own, not an expression in `detail`, so a test can
    /// ask it about a real `ContentView` — the view body is where this
    /// answer is switched on, never where it is decided.
    /// `DetailSurfaceWiringGuardTests` holds the view to that.
    func detailSurface(for tab: SessionTab) -> DetailSurface {
        let form = tab.connectionViewModel
        return DetailSurfacePlan.surface(
            liveness: tab.liveness,
            hostKeyPromptPending: form.hostKeyPrompt != nil,
            connectAttemptFailed: tab.connectFailure != nil,
            describesLostConnection: tab.lostConnection != nil,
            unacknowledgedFailure: form.unacknowledgedFailure != nil,
            formMode: form.mode, overviewSession: overviewSession(for: tab),
            newFormDismissed: tab.isNewConnectionFormDismissed,
            overviewGroup: tab.overviewGroupID == SessionGroupCatalog.allConnectionsID && overviewSession(for: tab) == nil
                ? SessionGroupCatalog.allConnections
                : sessionListViewModel.groups.first { $0.id == tab.overviewGroupID })
    }

    @ViewBuilder
    var detail: some View {
        let tab = activeTab
        // Captured once per `detail` evaluation (M8a T5 review, finding 3):
        // the sheet's four closures below all read THIS tab's bridge, not
        // `tabsModel.activeTab` at call time. Without this, ⌘1–9 switching
        // the active tab while the sheet is still up would make `onDismiss`/
        // `onCancel`/`onResolve` resolve the NEWLY active tab's prompt
        // instead of the one actually presenting the sheet. Invariant: the
        // sheet always talks to its presenting tab's bridge, for its whole
        // lifetime, regardless of what becomes active afterwards.
        let bridge = tab.conflictBridge
        Group {
            if let pair = tab.remotePair, let peers = pair.liveTabs,
               tabsModel.tabs.contains(where: { $0 === peers.left }),
               tabsModel.tabs.contains(where: { $0 === peers.right }) {
                RemotePairWorkspace(pair: pair, left: peers.left, right: peers.right,
                    settings: settingsStore,
                    onOpenFile: { item, owner, session in
                        guard EditorResolver.applicationURL(forFileName: item.name, settings: settingsStore) != nil
                        else { return false }
                        openInEditor(item, in: owner, session: session)
                        return true
                    },
                    onDropURLs: { urls, owner, session in uploadDropped(urls, in: owner, session: session) },
                    onPromise: { item, owner, session in remotePromiseProvider(for: item, in: owner, session: session) },
                    availableTargets: { CrossSessionTargets.targets(excluding: $0.id, in: tabsModel.tabs) },
                    onTransferToSession: { selection, owner, session, target in
                        transferToSession(selection, from: .remote, target: target, in: owner, session: session)
                    })
            } else if let session = tab.session {
                // The ONE decision both render conditions below read (P2
                // terminal-chrome milestone, Task 3 review round 1) —
                // `SessionTab.effectivePaneVisibility`, the SAME method the
                // toolbar's `paneToggleState` reads. Neither branch below
                // reads `tab.showsFiles`/`session.terminal.isVisible`
                // directly any more: those two raw booleans can disagree
                // (hide Files, disconnect, reconnect — `showsFiles` stays
                // `false` while a fresh `TerminalPanelViewModel` also
                // starts at `isVisible == false`), and reading them
                // straight into two independent `if`s rendered NEITHER
                // half while the toolbar's Files button, which DID go
                // through `PaneVisibility`'s repair, showed itself as
                // on-and-locked. Computing `visibility` once here and
                // reading `.showsFiles`/`.showsTerminal` off it closes that
                // gap — see `effectivePaneVisibility`'s own doc comment.
                let visibility = PaneVisibility.filesOnly
                VStack(spacing: 0) {
                    VSplitView {
                        if visibility.showsFiles {
                            HSplitView {
                                BrowserPane(
                                    fileWindows: tab.fileWindows,
                                    title: L10n.string("browser.paneLocal", "Local"),
                                    tint: DesignTokens.localAmber,
                                    softTint: DesignTokens.localSoft,
                                    viewModel: session.local,
                                    side: .local,
                                    transferGroupID: session.id,
                                    isActivePane: tab.commanderActiveSide == .local,
                                    onActivatePane: { tab.commanderActiveSide = .local },
                                    fileSystem: session.localFS,
                                    pasteboardWriter: { item in
                                        item.kind == .file
                                            ? NSURL(fileURLWithPath: item.path)
                                            : nil
                                    },
                                    onMenuAction: { entry, selection in
                                        switch entry {
                                        case .transferToOtherPane:
                                            transferSelection(
                                                selection, from: .local, in: tab, session: session)
                                        case .transferToSession(let target):
                                            transferToSession(
                                                selection, from: .local, target: target,
                                                in: tab, session: session)
                                        case .copyPath:
                                            copyPaths(of: selection)
                                        case .openInEditor:
                                            break   // never emitted for the local pane (menu model)
                                        case .rename, .infoAndPermissions, .newFolder, .newFile,
                                            .delete, .computeChecksum:
                                            break   // handled inside BrowserPane, never forwarded
                                        case .backendFileAction:
                                            break   // never contributed on the LOCAL pane (fileActions is nil here)
                                        }
                                    },
                                    crossSessionTargets: { CrossSessionTargets.targets(excluding: tab.id, in: tabsModel.tabs) },
                                    // Where this pane's "Transfer ▸ To the
                                    // other pane" would send (review C-1): the
                                    // REMOTE pane, which cannot receive while
                                    // it sits at a bucket list. A closure, so
                                    // the remote pane's current directory is
                                    // read at menu-build time rather than
                                    // baked into this view's identity.
                                    destinationScope: {
                                        BrowserScope(
                                            rootIsContainerList: session.remoteFS.rootIsContainerList,
                                            currentPath: session.remote.currentPath)
                                    },
                                    visibleColumns: settingsStore.visibleColumns,
                                    checksumAlgorithm: settingsStore.checksumAlgorithm,
                                    // The ledger belongs to the SESSION, not
                                    // to the pane (checksum-column review,
                                    // I2): this subtree is remounted per tab
                                    // (`.id(tab.id)` below) and again
                                    // whenever the Files half is hidden and
                                    // shown, and a digest the user paid a
                                    // server-side hash for must survive all
                                    // of that. The binding names THIS
                                    // session and refuses to write once it
                                    // is gone, so a hash still in flight
                                    // across a reconnect cannot land in the
                                    // next connection's ledger — see
                                    // `checksumLedgerBinding(for:in:)`.
                                    checksumLedger: tab.checksumLedgerBinding(
                                        for: .local, in: session),
                                    // "local" is not a `ConnectionKind`, so
                                    // there is no descriptor and no capability
                                    // flag to read here — the local file
                                    // system is asked instead, which for it is
                                    // the same question. See
                                    // `ChecksumAvailability`.
                                    supportsChecksum: ChecksumAvailability.isOffered(
                                        byLocalFileSystem: session.localFS),
                                    // Likewise off the local file system's own
                                    // declaration, since there is no descriptor.
                                    supportsPermissions: PermissionsAvailability.isOfferedByTheLocalFileSystem
                                )
                                .frame(minWidth: 280)

                                BrowserPane(
                                    fileWindows: tab.fileWindows,
                                    title: L10n.string("browser.paneRemote", "Remote"),
                                    tint: DesignTokens.remoteBlue,
                                    softTint: DesignTokens.remoteSoft,
                                    viewModel: session.remote,
                                    side: .remote,
                                    transferGroupID: session.id,
                                    isActivePane: tab.commanderActiveSide == .remote,
                                    onActivatePane: { tab.commanderActiveSide = .remote },
                                    onDropURLs: { urls in
                                        uploadDropped(urls, in: tab, session: session)
                                    },
                                    onOpenFile: { item in
                                        guard EditorResolver.applicationURL(
                                            forFileName: item.name, settings: settingsStore) != nil
                                        else { return false }
                                        openInEditor(item, in: tab, session: session)
                                        return true
                                    },
                                    fileSystem: session.remoteFS,
                                    pasteboardWriter: { item in
                                        item.kind == .file
                                            ? remotePromiseProvider(for: item, in: tab, session: session)
                                            : nil
                                    },
                                    onMenuAction: { entry, selection in
                                        switch entry {
                                        case .transferToOtherPane:
                                            transferSelection(
                                                selection, from: .remote, in: tab, session: session)
                                        case .transferToSession(let target):
                                            transferToSession(
                                                selection, from: .remote, target: target,
                                                in: tab, session: session)
                                        case .openInEditor:
                                            if let item = selection.first {
                                                openInEditor(item, in: tab, session: session)
                                            }
                                        case .copyPath:
                                            copyPaths(of: selection)
                                        case .rename, .infoAndPermissions, .newFolder, .newFile,
                                            .delete, .computeChecksum:
                                            break   // handled inside BrowserPane, never forwarded
                                        case .backendFileAction(let action):
                                            // Currently the only backend-contributed action is
                                            // S3's presigned URL (M14/T5) — keyed off `action.id`
                                            // so a future second contribution doesn't need a new
                                            // `BrowserMenuEntry` case, just another `if` here.
                                            // `selection.count == 1` mirrors the menu-model gate
                                            // (`BrowserContextMenu.entries`) that only ever offers
                                            // `backendFileAction` for a single selected file.
                                            if action.id == "s3.presignedURL",
                                                selection.count == 1, let file = selection.first,
                                                let provider = session.remoteFS as? PresignedURLProvider
                                            {
                                                // Same "no leading slash" convention
                                                // `S3FileSystem.objectKey(forPath:)` uses
                                                // internally: normalize first (collapses any
                                                // repeated slashes), then drop the single
                                                // leading one.
                                                let normalizedPath = RemotePath.normalizedAbsolute(file.path)
                                                let key = normalizedPath == "/" ? "" : String(normalizedPath.dropFirst())
                                                presignedSheetItem = PresignedSheetItem(
                                                    itemKey: key, provider: provider)
                                            }
                                        }
                                    },
                                    crossSessionTargets: { CrossSessionTargets.targets(excluding: tab.id, in: tabsModel.tabs) },
                                    fileActions: {
                                        BackendDescriptor.descriptor(for: tab.connectionViewModel.kind)
                                            .fileActions
                                    },
                                    // The mirror of the local pane's line
                                    // above. `LocalFileSystem` takes the
                                    // protocol default (`rootIsContainerList
                                    // == false`), so this always answers
                                    // "yes" today — asked through the same
                                    // function anyway, rather than assumed,
                                    // so a local pane that ever grows a
                                    // container root is covered by
                                    // construction.
                                    destinationScope: {
                                        BrowserScope(
                                            rootIsContainerList: session.localFS.rootIsContainerList,
                                            currentPath: session.local.currentPath)
                                    },
                                    visibleColumns: settingsStore.visibleColumns,
                                    checksumAlgorithm: settingsStore.checksumAlgorithm,
                                    // The remote side's own ledger — see the
                                    // local pane's above for why it lives on
                                    // the session. Two, because two panes are
                                    // two file systems and a path means
                                    // nothing across them.
                                    checksumLedger: tab.checksumLedgerBinding(
                                        for: .remote, in: session),
                                    // The capability, not the kind. Every
                                    // backend conforms to the checksum
                                    // protocol — WebDAV does so in order to
                                    // SAY it has none — so only the flag can
                                    // tell an offer from an empty one.
                                    supportsChecksum: ChecksumAvailability.isOffered(
                                        for: tab.connectionViewModel.kind),
                                    // Same shape: the descriptor's permission
                                    // model, read through the one function
                                    // that turns it into an offer.
                                    supportsPermissions: PermissionsAvailability.isOffered(
                                        for: tab.connectionViewModel.kind)
                                )
                                .frame(minWidth: 280)
                            }
                            .frame(minHeight: 200)
                            .layoutPriority(1)
                        }

                    }

                    // Resume banner: displayed when the ACTIVE tab has interrupted
                    // transfers (M5d/T4). Clicking "Resume" re-enqueues them with
                    // that tab's file systems and resume semantics enabled.
                    //
                    // No capability gate needed here (M12/T7b): the banner is
                    // governed by `ProtocolCapabilities.resumeMode`, but an
                    // S3 session can never populate `hasInterrupted` in the
                    // first place today — `S3FileSystem`'s read/write both
                    // throw `.protocolError` immediately (deferred to M13),
                    // so no S3 transfer can ever reach "interrupted" (that
                    // requires a transfer to have started and been cut off
                    // mid-flight). Gating this now would be dead code; M13
                    // is where `resumeMode == .rangeGet`'s actual mechanics
                    // (distinct from SSH's `.append`) need to be wired here.
                    if tab.transferQueue.hasInterrupted {
                        HStack {
                            Text(L10n.string(
                                "transfers.interrupted.banner",
                                "Interrupted transfers can be resumed."))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.string("transfers.interrupted.resume", "Resume")) {
                                tab.transferQueue.retryInterrupted(
                                    source: session.localFS,
                                    destination: session.remoteFS)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }

                    // Edit-open error (M5e/T4): subtle inline message, matching
                    // the resume banner's placement/styling above. Dismissible;
                    // cleared automatically on the next successful editor open.
                    if let editErrorMessage = tab.remoteTransferErrorMessage ?? tab.editErrorMessage {
                        HStack {
                            Text(editErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            Spacer()
                            // Icon-only hit target: the banner text is the
                            // error message and never says that the ✕ dismisses
                            // it, so the glyph needs its own hint — the same
                            // one the identical dismiss button in
                            // `FileSearchBar` carries.
                            Button {
                                tab.editErrorMessage = nil
                                tab.remoteTransferErrorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(L10n.string("common.close", "Close"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }

                    if tab.transfersPanelVisible {
                        TransferQueueBar(
                            viewModel: tab.transferQueue, sessionName: tab.titleName,
                            settingsStore: settingsStore)
                    }
                }
                .onChange(of: tab.transferQueue.items.count) { oldCount, newCount in
                    // A newly enqueued transfer reveals the bar (M11o) — the
                    // pre-M11o auto-appear behavior, now gated by the per-tab
                    // visibility flag. Only an INCREASE reveals; clearing or
                    // finishing items never force-hides.
                    if newCount > oldCount {
                        tab.transfersPanelVisible = true
                    }
                }
                .task(id: session.id) {
                    // Auto-refresh loop (M9c): lives inside the tab's `.id` identity,
                    // so switching tabs (or disconnecting) cancels it and the next
                    // active tab starts its own. Keyed on the SESSION id as a
                    // defensive guard (final review): even a hypothetical
                    // synchronous session swap without a branch flip would
                    // restart the loop against the new session.
                    // Reads the settings fresh every lap
                    // so changes apply without restart; skipped laps just sleep on.
                    while !Task.isCancelled {
                        let seconds = settingsStore.autoRefreshIntervalSeconds
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled, settingsStore.autoRefreshEnabled else { continue }
                        await session.remote.refreshQuietly()
                    }
                }
                .transferConflictSheet(bridge: bridge)
            } else if let candidate = tab.certificateBridge.currentCandidate {
                // Certificate trust prompt (M21/T10): the same "form is
                // hidden entirely while the trust decision is pending" shape
                // `ConnectionFormView.hostKeyPromptView` uses for the SSH
                // case, just driven by `tab.certificateBridge` instead of
                // `viewModel.hostKeyPrompt` — see that bridge's own doc
                // comment for why this state lives on the tab rather than on
                // `tab.connectionViewModel`.
                CertificatePromptView(
                    candidate: candidate,
                    onTrust: { tab.certificateBridge.resolve(trust: true) },
                    onCancel: { tab.certificateBridge.resolve(trust: false) }
                )
                .padding(24)
                .frame(minWidth: 420, maxWidth: 460)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                // The single "no session yet" surface (connection-liveness
                // plan, Task 6): `detailSurface(for:)` — which is
                // `DetailSurfacePlan.surface` over this tab's facts
                // (jump-and-groups plan, Task 1) — decides between
                // "Connecting…", the lost and failed surfaces, the session
                // overview and the ordinary form, and every branch below
                // only switches on that answer. See `ConnectionSurfacePlan`'s
                // own doc comment for why a pending host-key prompt forces
                // the form back regardless of `tab.liveness`, and
                // `DetailSurfacePlan`'s for why it also keeps the overview
                // off the form in that case. `Group`
                // keeps the plaintext-confirmation dialog below attached to
                // BOTH branches: the connector closure in `ContentView
                // .makeTab` can raise that confirmation WHILE `.connecting`
                // is showing (it asks before dispatching the dial, which
                // runs after `ConnectionViewModel.connect()` has already
                // set `state = .connecting`), so the dialog must not be
                // reachable only from the form branch.
                Group {
                    // Connecting surface branch (connection-liveness plan, Task 6)
                    let surface = detailSurface(for: tab)
                    if surface == .connecting {
                        ConnectingAttemptView(onCancel: {
                            // Best-effort on the dial itself (see
                            // `ConnectionViewModel.cancelConnecting()`'s own
                            // doc comment) — what makes the tab usable again
                            // is forcing `state` back on the FOREGROUND and
                            // running the one teardown path, not waiting for
                            // the abandoned dial to notice anything.
                            // `cancelConnecting()` also moves Core's own
                            // attempt token, so the abandoned dial's
                            // eventual writes (state, a host-key card) are
                            // refused at the source — see that method's own
                            // doc comment. `reconnectAttempt`/
                            // `isReconnecting` are the identical App-layer
                            // fix for the stored-session path's own lock
                            // (Critical 1, fix round 1): without resetting
                            // them HERE, the sidebar would stay disabled
                            // until the abandoned Task's own deferred
                            // cleanup finally ran.
                            tab.connectionViewModel.cancelConnecting()
                            tab.reconnectAttempt = UUID()
                            tab.isReconnecting = false
                            Task { await teardown(tab, reason: .userRequested) }
                        })
                    }
                    // Lost surface branch (connection-liveness plan, Task 7)
                    //
                    // Also `ReconnectWiringGuardTests`' anchor for this
                    // branch; that suite's own doc comment explains what it
                    // scans from here.
                    //
                    // The content is `LostConnectionPlan.content`'s, not
                    // assembled here: what a given reason says, and whether
                    // "Reconnect" is offered at all, is the one decision on
                    // this surface a test can actually check
                    // (`ReconnectPlanTests`), and it stays checkable only
                    // while this branch does no deciding of its own.
                    else if surface == .lost {
                        LostConnectionView(
                            content: LostConnectionPlan.content(
                                reason: tab.lostConnection?.reason ?? .probeGaveUp,
                                targetIsKnown: reconnectTarget(for: tab) != nil,
                                behaviour: settingsStore.reconnectBehaviour,
                                attempts: tab.lostConnection?.automaticAttempts ?? 0,
                                probeFailure: tab.lostConnection?.probeFailure),
                            onReconnect: { reconnect(tab) },
                            onDismiss: { dismissLostConnection(tab) })
                    }
                    // Failed-connect surface branch (failed-connect surface plan, Task 3)
                    //
                    // Also `ReconnectWiringGuardTests`' anchor for this
                    // branch, the same way the lost branch above is one.
                    //
                    // Every action here delegates: Retry — offered only
                    // when there is a stored session to dial — to
                    // `retryConnect(_:)`, which redials through the one
                    // shared `connect(in:stored:)` a sidebar connect uses, so
                    // this surface adds no second place a security rule
                    // could be forgotten; "Edit session" to the saved
                    // session editor, or Edit to the form for unsaved drafts;
                    // Close to the ordinary tab-close entry point,
                    // warnings and all; and the conversion pair — offered
                    // only when Core published a remedy — to
                    // `convertFailedKey(_:)` and
                    // `copyConversionCommand(for:)`, the first of which ends
                    // in `retryConnect(_:)` too rather than dialling for
                    // itself. What the surface SAYS is
                    // `ConnectFailurePlan.content`'s answer, and the
                    // technical text is `ConnectFailureDetailText.read`'s —
                    // this branch decides nothing of its own.
                    else if surface == .failed {
                        ConnectFailureView(
                            content: ConnectFailurePlan.content(
                                hasStoredSession: failedConnectTarget(for: tab) != nil,
                                remedy: tab.connectionViewModel.lastFailureRemedy,
                                category: tab.connectionViewModel.lastFailureCategory),
                            details: ConnectFailureDetailText.read(
                                from: tab.connectionViewModel.state),
                            onRetry: { retryConnect(tab) },
                            onEdit: { dismissConnectFailure(tab) },
                            onEditSession: { editFailedSession(tab) },
                            // The tab's door, on its failed-connect surface
                            // (design §1) — the toolbar is the same door's
                            // other surface. It
                            // OPENS the panel and measures nothing — the
                            // maintainer decided on 2026-09-02 that a failed
                            // connect does not start a diagnosis by itself,
                            // so this stays a control the user presses.
                            onDiagnose: { showDiagnostics(for: .tab(tab)) },
                            onConvertKey: { convertFailedKey(tab) },
                            onCopyCommand: { copyConversionCommand(for: tab) },
                            onClose: { requestClose(tab) })
                    }
                    // Session overview branch (session overview plan, Task
                    // 2). A single click on a stored session shows what is
                    // stored about it instead of the empty "New connection"
                    // form — read-only, with the window's own Connect, Edit
                    // and Diagnose handed over as values.
                    //
                    // WHEN it is shown is `DetailSurfacePlan.surface`'s
                    // answer and nothing of this branch's own (jump-and-
                    // groups plan, Task 1). The condition used to be written
                    // here — a selection and a `.new` form — and it was
                    // checked before the form, which is where TOFU's trust
                    // card and the text of every failure a person must read
                    // live. A sidebar connect always selects its row first,
                    // so a new host's card sat under this overview and the
                    // dial waited for an answer nobody could see: the
                    // maintainer's "second session through the same jump
                    // returns to the session info". The plan's doc comment
                    // states the rule now; `DetailSurfaceWiringGuardTests`
                    // holds this branch to reading it.
                    //
                    // WHICH session it describes is `overviewSession(for:)`'s
                    // answer, handed through the plan: per tab FIRST, then
                    // the window's (Detachable Tabs plan, Task 5 fix round
                    // 1). The window's selection alone would give every
                    // unconnected tab the same overview, which matches
                    // where the one sidebar is; a RESTORED window's tabs
                    // were each pointed at a different session, so the
                    // tab's own restored pointer is read ahead of it.
                    else if case .groupOverview(let group) = surface {
                        SessionGroupOverviewView(
                            group: group,
                            sessions: SessionGroupCatalog.sessions(
                                in: group.id, sessions: sessionListViewModel.sessions, groups: sessionListViewModel.groups),
                            groups: sessionListViewModel.groups, loginSets: sessionListViewModel.loginSets,
                            onConnectSession: SessionRowConnectEffect { connectFromGroupCard($0) },
                            onEdit: { editStored($0) },
                            onDiagnose: { showDiagnostics(for: .stored($0)) })
                    }
                    else if case .overview(let stored) = surface {
                        // Resolved on the main actor, where the two lists
                        // live, and handed down as names — see
                        // `SessionOverviewNames` for why the model takes
                        // names rather than the ids the session carries.
                        let names = overviewNames(for: stored)
                        SessionOverviewView(
                            session: stored,
                            groupName: names.group,
                            loginSetName: names.loginSet,
                            // The same three entries the sidebar's own row
                            // menu reaches, and no fourth of anything: the
                            // connect one as an effect value the view cannot
                            // fire without naming an input.
                            onConnectSession: SessionRowConnectEffect { connectFromSidebar($0) },
                            onEdit: { editStored($0) },
                            onDiagnose: { showDiagnostics(for: .stored($0)) },
                            )
                            .modifier(SessionOverviewFailureAlert(
                                form: tab.connectionViewModel, onEdit: { editStored(stored) }))
                    } else if surface == .dismissedForm {
                        VStack(spacing: 16) {
                            Button(L10n.string("connection.title", "New connection")) {
                                newConnection()
                            }
                            .buttonStyle(.polishedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Align the form to the top instead of centering it
                        // vertically (user feedback 2026-07-10, M5c/T0) —
                        // otherwise the compact window has a lot of empty
                        // space below the content.
                        ConnectionFormView(
                            viewModel: tab.connectionViewModel,
                            sessionList: sessionListViewModel,
                            globalTerminalType: settingsStore.terminalType,
                            managedKeyStore: managedKeyStore,
                            secretStore: secretStore,
                            resolveLoginSetForSubmit: {
                                let form = tab.connectionViewModel
                                let refusals = sessionListViewModel.prepareForSubmit(form: form)
                                for refusal in refusals {
                                    form.showFailure(
                                        message: SubmitRefusalText.message(for: refusal), field: refusal.field)
                                }
                                return refusals.isEmpty
                            },
                            onSaveEdited: { stored, secret in
                                var stored = stored
                                var effectiveSecret = secret
                                switch maybeCreateNewLoginSet(
                                    from: tab.connectionViewModel, editedSession: stored
                                ) {
                                case .saved(let newSetID):
                                    // The secret now lives under the new set's id —
                                    // don't also duplicate it into the session's own
                                    // keychain slot.
                                    stored.loginSetID = newSetID
                                    effectiveSecret = nil
                                case .failed:
                                    return false
                                case .notRequested where stored.loginSetID != nil:
                                    // Set mode: the set already owns the secret.
                                    effectiveSecret = nil
                                case .notRequested:
                                    break
                                }
                                // Jump secret (M10c/T3): `stored.jump` was already
                                // built by `validateForEditSave()` (Set mode carries
                                // only `loginSetID`, Manual carries the manual
                                // fields + the EXISTING `secretID` it remembered) --
                                // `updateSession` itself gates on `jump.loginSetID
                                // == nil` before writing this, so passing it
                                // unconditionally is safe in Set/Manual mode.
                                //
                                // Session mode (M11a/T3): `jumpPassword` was just
                                // filled with the REFERENCED session's own resolved
                                // secret (`SessionListViewModel.resolveJumpSession`,
                                // spec §4a) --
                                // passing that through here would copy it into the
                                // jump's supposedly UNUSED `secretID` slot (spec §1:
                                // "ungenutzt") on every save, not just the
                                // manual→session switch `cleanOrphanedJumpSlot`
                                // guards against. `nil` keeps that slot untouched.
                                guard sessionListViewModel.updateSession(
                                    stored, newSecret: effectiveSecret,
                                    jumpSecret: tab.connectionViewModel.jumpSourceMode == .session
                                        ? nil : tab.connectionViewModel.jumpPassword,
                                    filledJumpPassphrase:
                                        tab.connectionViewModel.filledJumpPassphrase)
                                else { return false }
                                tab.connectionViewModel.endEditing()
                                return true
                            },
                            // Save without dialing — the form's own route
                            // into `SessionListViewModel.save`, and what the
                            // tab menu's "Save as Session…" ultimately lands
                            // on. Validation already ran inside the button.
                            onSaveNew: { saveFormAsSession(in: tab) },
                            onCancelEdit: { tab.connectionViewModel.endEditing() },
                            onCancelNew: { tab.dismissNewConnectionForm() },
                            onConnectEdited: { stored in
                                // onSaveEdited may have rewired loginSetID (e.g. "save as new
                                // login set") on its own local copy of `stored`, which never
                                // reaches this closure's parameter. `updateSession` inside
                                // onSaveEdited already reloaded the list synchronously, so look
                                // up the just-persisted session by id and connect with that.
                                let current = sessionListViewModel.sessions.first(where: { $0.id == stored.id }) ?? stored
                                connect(in: tab, stored: current)
                            },
                            // The error dialog's door. Same tab, same entry
                            // as the failed-connect surface above — the dialog
                            // and the surface answer the same failure from two
                            // places in the flow.
                            onDiagnose: { showDiagnostics(for: .tab(tab)) },
                            // Read fresh at Connect-button-click time, inside
                            // `ConnectionFormView`'s own handler, NOT here —
                            // see `ConnectionFormView.currentReconnectAttempt`'s
                            // own doc comment for why a closure (fix round 3)
                            // rather than a plain value captured at THIS
                            // render.
                            currentReconnectAttempt: { tab.reconnectAttempt }
                        // Ad-hoc connect completion (connection-liveness plan, Task 6)
                        ) { fs, myAttempt in
                            // `myAttempt` is the token `ConnectionFormView`'s
                            // own Connect handler captured BEFORE dialing —
                            // see that view's `currentReconnectAttempt` doc
                            // comment for why capturing there (not here,
                            // after the dial) is what fix round 3 settled on
                            // as the one rule both connect paths share.
                            await handleAdHocConnected(fs, in: tab, attempt: myAttempt)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                // Plaintext-transport confirmation (M21/T10): asked by the
                // connector closure (`ContentView.makeTab`) before it ever
                // dispatches a connect whose transport is `.optionalTLS` and
                // whose endpoint is `http://`. Declining resolves the
                // waiting `confirmPlaintext()` call with `false`, which
                // throws `RemoteFSError.connectionFailed` — the connect
                // never happens (see that closure's own comment).
                .confirmationDialog(
                    L10n.string("transport.plaintext.title", "Send credentials unencrypted?"),
                    isPresented: Binding(
                        get: { tab.plaintextConfirmationPending },
                        set: { _ in /* answered exclusively through the buttons below */ }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                        tab.resolvePlaintextConfirmation(confirmed: false)
                    }
                    Button(L10n.string("connection.connect", "Connect"), role: .destructive) {
                        tab.resolvePlaintextConfirmation(confirmed: true)
                    }
                } message: {
                    Text(L10n.string(
                        "transport.plaintext.body",
                        "This connection uses http://, so the password travels in the clear. "
                            + "Use https:// where the server offers it."))
                }
            }
        }
        // Load-bearing identity (M8a/T3 review): forces this whole per-tab
        // subtree — the connected browser layout AND the form branch — to
        // remount on every tab switch. Without it, two connected tabs would
        // share the same SwiftUI view identities: `SSHTerminalView` binds
        // `onOutput` and replays its buffer only in `makeNSView` --
        // `updateNSView` touches font and cursor style and nothing else --
        // so a tab switch would keep rendering/typing into the OLD tab's
        // shell instead of rebinding to the new one. `BrowserPane`/
        // `ConnectionFormView` `@State` would leak across tabs the same way.
        .id(tab.id)
    }


}

@MainActor
enum LivenessProbeCoverage {
    static func tabsToProbe(from tabs: [SessionTab]) -> [SessionTab] {
        tabs.filter { $0.isConnected }
    }
}

/// Connection status is window-scoped and independent of the selected tab.
@MainActor
enum SessionSidebarConnections {
    static func connectedSessionIDs(in tabs: [SessionTab]) -> Set<UUID> {
        Set(tabs.filter { $0.isConnected }.compactMap(\.activeStoredSessionID))
    }
}

struct LivenessProbeRunner: View {
    let tab: SessionTab
    let settingsStore: SettingsStore
    /// Routes to `ContentView.handleLivenessGiveUp(_:)` — passed in rather
    /// than called directly because this type has no access to
    /// `ContentView`'s own instance state, only to what its caller
    /// (`ContentView.splitLayout`) hands it. `handleLivenessGiveUp` is the
    /// real function a test drives to prove the `teardown(_:)`-then-`.lost`
    /// order holds (`LivenessGiveUpOrderingTests`); the probe loop's
    /// `.giveUp` case delegates to it rather than inlining that order a
    /// second time, so there is exactly one place that order is written.
    let onGiveUp: (SessionTab) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: tab.session?.id) {
                // Nothing to probe without a session. The session is NOT
                // captured here for the probe itself to use — each probe
                // re-reads it inside `LivenessProbeStep.perform`, so a tab
                // that disconnected and reconnected while a probe was in
                // flight cannot have the old connection's answer written
                // onto the new one.
                guard tab.session != nil else { return }
                var consecutiveFailures = 0
                // Liveness probe (Task 4): reads settings fresh every lap so
                // a mid-session change applies without restart; skipped laps
                // just sleep on — the same shape `detail`'s own auto-refresh
                // loop uses.
                while !Task.isCancelled {
                    let usesTLS = tab.connectionViewModel.lastConnectedConfig?.usesTLSTransport == true
                    // The switch, not a sentinel interval, decides whether
                    // a non-TLS tab probes at all — `keepAliveIntervalSeconds`
                    // always reads 15…600 now (a stored `0` reads back as
                    // the default), so there is no interval value left that
                    // could mean "off". Sleep a fixed beat and recheck
                    // rather than spin, so turning the switch back on later
                    // takes effect without restarting the tab. NARROWING an
                    // already-running interval instead only takes effect
                    // once the current sleep call completes, up to the OLD,
                    // LARGER interval's own length — see
                    // `LivenessProbePolicy.idleRecheckSeconds`'s own doc
                    // comment for that asymmetry stated precisely.
                    // TLS routes need application traffic even when optional idle
                    // checks are off; TCP keepalive alone cannot refresh a gateway.
                    if !usesTLS {
                        guard settingsStore.keepAliveEnabled else {
                            try? await Task.sleep(for: .seconds(LivenessProbePolicy.idleRecheckSeconds))
                            continue
                        }
                    }
                    let interval = LivenessProbePolicy.interval(
                        configured: settingsStore.keepAliveIntervalSeconds, usesTLS: usesTLS)
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { continue }
                    probing: while !Task.isCancelled {
                        let action = LivenessProbePolicy.decide(
                            queueIsBusy: tab.transferQueue.isActive && !usesTLS,
                            consecutiveFailures: consecutiveFailures)
                        switch action {
                        case .skip:
                            // For non-TLS routes, running traffic proves the connection better
                            // than any probe would (design spec §2.1) — so
                            // the VISIBLE state says so too, not just the
                            // internal failure count: `consecutiveFailures`
                            // resets here for the same reason a stale
                            // `.degraded` from before the busy gap must not
                            // keep reading `.degraded` for the traffic's
                            // whole duration (fix round 2) — carrying either
                            // one across the gap would let a later give-up,
                            // or a stale dot, stand on evidence that
                            // predates the very traffic that disproved it.
                            consecutiveFailures = 0
                            tab.liveness = .connected
                            break probing
                        case .probe, .probeAgainNow:
                            let timeoutSeconds = LivenessProbePolicy.probeTimeout(forInterval: interval)
                            // The race AND the write of its result both live
                            // in `LivenessProbeStep.perform` — see that
                            // type's own doc comment for why they cannot be
                            // separated: the guard that makes the write
                            // legitimate has to sit between them, and a
                            // write spelled out here would be a write with
                            // no guard in front of it.
                            let result = await LivenessProbeStep.perform(
                                on: tab, timeoutSeconds: timeoutSeconds)
                            guard result != .abandoned else { return }
                            if result == .alive {
                                consecutiveFailures = 0
                                break probing
                            } else {
                                consecutiveFailures += 1
                                // Loop again immediately, without sleeping
                                // the full interval: `decide` now sees the
                                // incremented failure count and answers
                                // `.probeAgainNow` (one immediate retry) or
                                // `.giveUp`.
                            }
                        case .giveUp:
                            // Delegates to `onGiveUp` rather than inlining
                            // `teardown(_:)`-then-`.lost` here a second
                            // time (fix round 3) — see `onGiveUp`'s own doc
                            // comment for why, and `handleLivenessGiveUp`'s
                            // for the order itself and why it matters.
                            //
                            // No cancellation guard of its own, unlike the
                            // probe arm: this one is reached only by
                            // the enclosing `while !Task.isCancelled`, and
                            // `decide` is synchronous, so nothing can
                            // suspend between that check and this call on
                            // the main actor. A guard here would restate a
                            // condition that cannot have changed.
                            await onGiveUp(tab)
                            return
                        }
                    }
                }
            }
    }
}

/// One liveness probe and the write of its answer, together (connection-
/// liveness plan, whole-branch final review, finding I-1) — the race and
/// the `tab.liveness` write cannot be separated, because the guard that
/// makes the write legitimate is what has to sit between them.
///
/// `LivenessProbeRace.run` is deliberately NOT cancellation-aware: it
/// resolves a `withCheckedContinuation` from two unstructured tasks, so
/// cancelling the probing task does not make it return early — only the
/// operation finishing or `LivenessProbePolicy.probeTimeout(forInterval:)`
/// elapsing does (see `LivenessProbeRace`'s own doc comment for why that
/// shape was chosen, and what the structured alternative did instead). The
/// probing task therefore resumes AFTER it was cancelled, up to a full
/// probe timeout later, and a write placed straight after the `await` would
/// land on a tab whose session `teardown(_:)` has already torn down and
/// whose `liveness` it has already cleared to `nil`.
///
/// Two things that write would do, both closed by refusing it:
///
/// - a liveness dot on a tab that is sitting on the connection form with no
///   session at all, which is the same "state that outlives what it
///   describes" class that moved `liveness` onto the tab in the first
///   place, attacked from the other side;
/// - worse, the loss of the way to abandon a dial. `ConnectionSurfacePlan
///   .surface` answers `.form` for `.connected` and for `.degraded` alike,
///   so a stale write arriving during the reconnect-in-place dial replaces
///   the "Connecting…" surface, and with it the Cancel control, while that
///   dial is still running.
///
/// The guard is two conditions, not one. `Task.isCancelled` catches the
/// cancelled runner; re-reading `tab.session` and comparing its id catches
/// the tab that disconnected and reconnected during the flight, where the
/// task is alive and healthy and the answer in hand is nevertheless about a
/// connection that no longer exists.
///
/// `LivenessProbeCancellationTests` drives this function inside a task it
/// cancels mid-flight, against a `stat` that never responds — the real
/// race, really cancelled — and pins that nothing is written.
@MainActor
enum LivenessProbeStep {
    /// What one probe settled on. `.abandoned` is not a failure and must
    /// not be counted as one: it says the question stopped being worth
    /// answering, not that the peer failed to answer it.
    enum Result: Equatable {
        /// The peer answered inside the deadline; the tab now reads `.connected`.
        case alive
        /// The deadline won, or the `stat` failed; the tab now reads `.degraded`.
        case failed
        /// Cancelled, or the session went away, while the probe was in
        /// flight. NOTHING was written and the caller must stop.
        case abandoned
    }

    /// The failure is kept, not discarded (lost-connection cause,
    /// 2026-09-19): the race settles on `nil` for an answer, on the
    /// timeout's own value when the deadline wins, or on what
    /// `LivenessProbeFailure.classify(_:)` made of the error the
    /// `stat` threw. A failure is written to `tab.lastProbeFailure` and
    /// logged, one `info` line per probe, behind the same guard as the
    /// `liveness` write — an abandoned probe writes and logs nothing.
    /// `LivenessProbeErrorKeptGuardTests` holds this body to catching the
    /// error rather than dropping it.
    static func perform(on tab: SessionTab, timeoutSeconds: Int) async -> Result {
        guard let session = tab.session else { return .abandoned }
        let failure: LivenessProbeFailure? = await LivenessProbeRace.run(
            timeoutSeconds: timeoutSeconds, onTimeout: .timeout(seconds: timeoutSeconds)
        ) {
            do {
                _ = try await session.remoteFS.stat(path: session.homePath)
                return nil
            } catch {
                return LivenessProbeFailure.classify(error)
            }
        }
        guard !Task.isCancelled, tab.session?.id == session.id else { return .abandoned }
        tab.lastProbeFailure = failure
        guard let failure else {
            tab.liveness = .connected
            return .alive
        }
        tab.liveness = .degraded
        let tabID = tab.id
        DiagnosticLog.shared.log(
            .info, "connect", LivenessLogLines.probeFailed(tab: tabID, failure: failure))
        return .failed
    }
}

/// Races an async operation against a deadline, `false` if the deadline
/// wins (connection-liveness plan, Task 4, fix round 1) — pulled out of
/// `LivenessProbeRunner` so `Tests/macSCPAppKitTests/` can drive it directly
/// with a fake `RemoteFileSystem` whose `stat` never resumes: the exact case
/// the previous shape (`withTaskGroup`) could not survive. Its caller is
/// `LivenessProbeStep.perform`, which is where the answer this returns is
/// turned into a write, and where the guard in front of that write lives.
///
/// `withTaskGroup` implicitly awaits every remaining child before its own
/// scope returns, even one abandoned via `cancelAll()` — that is a
/// structured-concurrency guarantee, not a bug, but it defeats a timeout
/// when the abandoned child cannot finish early. Citadel's own path into
/// NIO ends in a bare `EventLoopFuture.get()` with no cancellation handler,
/// so a cancelled `stat` against a connection that has actually died does
/// not finish early — measured at 3.00s against a 1s deadline with the
/// `withTaskGroup` shape, on the exact case this whole probe exists to
/// catch: a connection that dies silently, where `stat` never returns at
/// all. With that shape the probe hangs instead of timing out, and the
/// state stays `.connected` — the opposite of the intent.
///
/// Two unstructured `Task`s race instead of one structured child: neither
/// is a child `run(timeoutSeconds:operation:)` itself awaits, so returning
/// does not wait on whichever one loses. The abandoned operation may keep
/// running in the true background afterward — cancelling it is best-effort
/// only, for the same reason `EventLoopFuture.get()` defeated the previous
/// shape's own cancellation — but that no longer blocks the caller.
///
/// Exactly-once resumption (this project's standing continuation invariant;
/// see `ConflictPromptBridge`'s doc comment for the fuller treatment): `run`
/// is `@MainActor`, so its synchronous `withCheckedContinuation` closure —
/// where `Box` is constructed and both racing tasks are created — runs on
/// the main actor without ever yielding, which is what guarantees both
/// `box.operationTask` and `box.timeoutTask` are assigned before either
/// task's own `@MainActor`-isolated body can start.
///
/// The two racing calls to `resume(with:)` are NOT symmetric —
/// `LivenessProbeRaceTests
/// .aStatThatNeverRespondsStillReportsFailureWithinTheDeadline` is exactly
/// the case where the operation task's own call never happens at all,
/// because `await operation()` never returns to reach it. "At least once"
/// instead comes from the timeout task alone: `Task.sleep` completes on
/// its own schedule regardless of what `operation` does, so its call to
/// `resume(with:)` is guaranteed no matter how the race goes. "At most
/// once" comes from `Box.resume(with:)` itself — the only place the
/// continuation is taken and resumed, reachable only by hopping onto the
/// main actor, so whichever call (one or two) arrives is serialized, and
/// `continuation == nil` on a second call is what makes a double
/// resumption (which would trap) impossible.
@MainActor
enum LivenessProbeRace {
    /// `onTimeout` is what the race settles on when the deadline wins, so
    /// the caller can tell a deadline from an answer that said "failed"
    /// (lost-connection cause, 2026-09-19). It replaced a `Bool`-only form,
    /// whose convenience overload fix round 1 deleted: after the probe moved
    /// to this one, nothing under `Sources/` called it, and a second
    /// spelling nothing uses is a second thing to keep true.
    static func run<Value: Sendable>(
        timeoutSeconds: Int, onTimeout: Value,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let box = Box(continuation: continuation)
            box.operationTask = Task { @MainActor in
                let answer = await operation()
                box.resume(with: answer)
            }
            box.timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                box.resume(with: onTimeout)
            }
        }
    }

    @MainActor
    private final class Box<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        /// The only place `continuation` is taken and resumed — see this
        /// type's own doc comment for the exactly-once argument.
        func resume(with value: Value) {
            guard let continuation else { return }
            self.continuation = nil
            operationTask?.cancel()
            timeoutTask?.cancel()
            continuation.resume(returning: value)
        }
    }
}

/// What the tab's connection area should show while it has no active
/// session (connection-liveness plan, Task 6) — the ONE surface Task 6's
/// `.connecting` case renders through, which Task 7 then added its own
/// `lost` case to without touching this type's call site in
/// `ContentView.detail`, and which the failed-connect surface plan's Task 3
/// added `failed` to — that one DID change the call site, which now passes
/// a third fact (see `ConnectionSurfacePlan.surface`). The jump-and-groups
/// plan's Task 1 moved that call site out of the view body and into
/// `DetailSurfacePlan.surface`, which composes this answer with the
/// session overview's. Named per the design
/// spec's own framing
/// (`docs/superpowers/specs/2026-08-21-connection-state-design.md` §4):
/// one and the same tab area for connecting, connected and lost.
enum ConnectionAttemptSurface: Equatable {
    /// The ordinary new-connection/edit form (`ConnectionFormView`).
    case form
    /// "Connecting…" with a Cancel control (Task 6).
    case connecting
    /// The lost-connection surface: what happened, and the way back (Task
    /// 7) — `LostConnectionView`, driven by `LostConnectionPlan.content`.
    case lost
    /// The failed-connect surface: an attempt that never reached a session
    /// (failed-connect surface plan, Task 3) — `ConnectFailureView`, driven
    /// by `ConnectFailurePlan.content`. Distinct from `.lost`, which is
    /// about a connection that existed and dropped.
    case failed
}

/// Decides `ConnectionAttemptSurface` from the facts `ContentView
/// .detail` already has in hand — handed over through
/// `ContentView.detailSurface(for:)` and `DetailSurfacePlan.surface`, this
/// function's one production caller (counted with `grep` over `Sources/`
/// on 2026-09-18; `ConnectionSurfacePlanTests` and `ReconnectPathTests`
/// call it directly as well) — pulled out as a plain function so
/// `Tests/macSCPAppKitTests/` can exercise every combination directly,
/// rather than the decision living inline in a view body this project has
/// no way to render (the same move `LivenessDotPlan`, Task 5, made for the
/// tab-strip dot).
enum ConnectionSurfacePlan {
    /// `hostKeyPromptPending` is `tab.connectionViewModel.hostKeyPrompt !=
    /// nil` at the call site. TOFU's trust card lives INSIDE
    /// `ConnectionFormView` (`hostKeyPromptView`), unlike the WebDAV/S3
    /// certificate prompt, which is a sibling surface `ContentView.detail`
    /// already checks before ever reaching this function
    /// (`tab.certificateBridge.currentCandidate`) — so a `.connecting`
    /// surface that hid `ConnectionFormView` unconditionally would hide the
    /// one thing on screen a first connection to an unknown host needs
    /// answered. TOFU is a hard stop in this project (see the architecture
    /// invariants), never bypassed by a UI surface picking the wrong
    /// branch — this override is what keeps that true here.
    ///
    /// `.lost` (Task 7) is answered here rather than by a second, parallel
    /// decision in `ContentView.detail`, so the host-key override above
    /// covers it too: an automatic reconnect that raises a trust card while
    /// the tab still reads `.lost` must show that card, not an error view
    /// explaining that the connection dropped.
    ///
    /// `connectAttemptFailed` is `tab.connectFailure != nil` at the call
    /// site (failed-connect surface plan, Task 3) — a connect attempt that
    /// ended on the wire, with nothing connected and no earlier connection
    /// to explain. Before this task every such attempt left `liveness` at
    /// `nil` and therefore landed in the `.form` group below, which is the
    /// maintainer's complaint this surface answers: the tab fell back to
    /// the entry mask as if nothing had been asked for.
    ///
    /// It is consulted ONLY in the `nil` arm, deliberately. `.lost` is
    /// answered above it, so a reconnect that fails from the lost surface
    /// still returns to the surface that explains the drop rather than
    /// being reclassified as a fresh failure. `.connected`/`.degraded` keep
    /// answering `.form` unconditionally: a tab with a live session does
    /// not render this area at all (`ContentView.detail` reaches this
    /// function only while `tab.session == nil`), and letting a stale
    /// failure speak for a connected tab would be a new way to be wrong
    /// about a tab that is fine.
    static func surface(
        for liveness: ConnectionLiveness?, hostKeyPromptPending: Bool,
        connectAttemptFailed: Bool
    ) -> ConnectionAttemptSurface {
        guard !hostKeyPromptPending else { return .form }
        switch liveness {
        case .connecting: return .connecting
        case .lost: return .lost
        case .connected, .degraded: return .form
        case nil: return connectAttemptFailed ? .failed : .form
        }
    }
}

/// Why a tab's connection is gone, at the coarseness the lost-connection
/// surface and the reconnect policy both read (connection-liveness plan,
/// Task 7).
enum LostConnectionReason: Equatable {
    /// The liveness probe gave up on a session that had been connected.
    case probeGaveUp
    /// A reconnect attempt failed for a reason another attempt might not
    /// hit — a timeout, a refused connection, a host that is still booting.
    case reconnectFailed
    /// The last attempt stopped at something only a person can answer: an
    /// unknown or changed host key, or a key passphrase MacSCP does not
    /// have. Repeating it unattended would only raise the same question
    /// again on a schedule, so this reason stops background retrying
    /// outright — see `ReconnectPlan.step`. Comes from Core's own
    /// `ConnectFailureKind.needsPerson`, never from reading a message.
    case needsPerson
}

/// What a tab remembers about a connection that dropped (connection-
/// liveness plan, Task 7) — stored on `SessionTab.lostConnection`.
///
/// Carries an id and an enum, never a host name, a server message or a
/// typed value: the design spec's §10 rule (no secret and no user-typed
/// value on the error view) is a property of what this type is able to
/// hold, not a habit at the call site. `LostConnectionContent`, what
/// actually reaches the screen, has the same shape for the same reason.
struct LostConnection: Equatable {
    var reason: LostConnectionReason
    /// The stored session to redial, or `nil` for an ad-hoc connection —
    /// one typed into the form and never saved, whose secrets
    /// `ContentView.teardown(_:)` has already cleared, so there is nothing
    /// left to redial WITH. That case offers the form back instead of a
    /// Reconnect button; see `LostConnectionPlan.content`.
    var storedSessionID: UUID?
    /// How many unattended attempts this episode has already started.
    /// Drives `ReconnectBackoff.delay(forAttempt:)` and, under
    /// `.onceThenAsk`, the "once" itself. Counts attempts STARTED, not
    /// attempts finished — an attempt that is still dialing must not be
    /// started a second time by the same schedule.
    var automaticAttempts = 0
    /// Why the probe that gave up failed, at the coarseness the surface
    /// names it (lost-connection cause, 2026-09-19) — an enum, like
    /// everything else here, never the error or its text. `nil` for an
    /// episode the probe did not open, and read by the surface only while
    /// `reason` is still `.probeGaveUp`.
    var probeFailure: LivenessProbeFailure.Kind? = nil
}

/// What a tab remembers about a connect attempt that failed on the wire
/// (failed-connect surface plan, Task 3) — stored on `SessionTab
/// .connectFailure`, and the fact `ConnectionSurfacePlan` reads to put the
/// failed-connect surface up instead of the form.
///
/// The same shape, and the same reason, as `LostConnection` above: an
/// optional id and nothing else. There is no field a host name, a typed
/// value or a server message could be put into, so what the SURFACE can
/// show is bounded by what this type can hold. The full technical text the
/// details dialog shows is deliberately NOT kept here — it is read from
/// `ConnectionViewModel`'s own published `.failed` state when the dialog
/// asks for it (`ConnectFailureDetailText.read(from:)`), so there is one text,
/// the one the layer below published, and no second copy that could drift
/// from it or outlive the attempt it describes.
struct ConnectFailure: Equatable {
    /// The stored session the failed attempt dialed, or `nil` when it was
    /// ad-hoc — typed into the form and never saved, so there is nothing
    /// stored to open an editor on. Resolved against the LIVE session list
    /// when read (`ContentView.failedConnectTarget(for:)`), never trusted
    /// as a session that still exists, for the same reason
    /// `LostConnection.storedSessionID` is not: a session can be deleted
    /// while its tab sits on this surface.
    var storedSessionID: UUID?
}

/// The lost-connection surface's whole content (connection-liveness plan,
/// Task 7): catalog keys and their English defaults, and two booleans.
///
/// There is deliberately no `String` field here that a host name, a server
/// error, or a form value could be put into — that is what makes the design
/// spec's §10 rule (the error view must contain no secret and no value the
/// user typed) checkable rather than merely intended. `ReconnectPlanTests`
/// pins that every reachable content value is one of a fixed, enumerated
/// set of catalog keys.
///
/// The two button labels are fields here rather than literals in the view
/// (round 2, after review): with them left in the view, this type covered
/// the text on the surface but not all of it, and the claim that the key
/// scan is exhaustive was true only of the part that happened to live here.
/// Everything the surface renders now comes through this type.
struct LostConnectionContent: Equatable {
    struct Message: Equatable {
        let key: String
        let fallback: String
    }

    let title: Message
    let body: Message
    /// Why the probe gave up, in one fixed sentence per cause, under the
    /// body (lost-connection cause, 2026-09-19). `nil` when the body is
    /// not the probe's, or the episode carries no cause. Never an error's
    /// own text — the rule of 2026-09-19 for every connection surface.
    let detail: Message?
    /// A second line under the body, when there is something to add about
    /// what MacSCP is doing on its own. `nil` when the body already says
    /// everything.
    let hint: Message?
    /// The redial button, or `nil` when there is nothing to redial.
    let reconnectButton: Message?
    /// The way back to the ordinary connection form. Always offered — even
    /// with a redial available, leaving the surface has to be possible.
    let dismissButton: Message
}

/// Builds `LostConnectionContent` (connection-liveness plan, Task 7) —
/// a plain function over three facts, for the same reason `LivenessDotPlan`
/// (Task 5) and `ConnectionSurfacePlan` (Task 6) are: no test in this
/// project renders SwiftUI, so the decision has to live somewhere a test
/// can call.
enum LostConnectionPlan {
    /// `targetIsKnown` is "this tab's dropped connection names a stored
    /// session that is still in the list" — resolved at the call site
    /// against `SessionListViewModel.sessions`, because a session can be
    /// deleted while its tab sits on this surface, and offering to redial
    /// something that no longer exists is a button that cannot work.
    ///
    /// `attempts` is `LostConnection.automaticAttempts`. It matters only to
    /// `.onceThenAsk`, which is the behaviour whose whole state is "has the
    /// one attempt happened yet" — and which round 1 left with no hint at
    /// all, so a user could not tell that MacSCP was about to try by
    /// itself, nor afterwards that it already had. That invisibility, not
    /// the delay before the attempt, was the friction.
    ///
    /// `probeFailure` is `LostConnection.probeFailure`. It adds the detail
    /// line only under the probe's own body: once a reconnect attempt has
    /// replaced the reason, the body describes that attempt, and the old
    /// drop's cause under it would describe something else.
    static func content(
        reason: LostConnectionReason, targetIsKnown: Bool, behaviour: ReconnectBehaviour,
        attempts: Int, probeFailure: LivenessProbeFailure.Kind? = nil
    ) -> LostConnectionContent {
        let body: LostConnectionContent.Message
        switch reason {
        case .probeGaveUp:
            body = .init(
                key: "connection.lost.body.probe",
                fallback: "The host stopped answering, so MacSCP closed the session.")
        case .reconnectFailed:
            body = .init(
                key: "connection.lost.body.retryFailed",
                fallback: "MacSCP could not reach the host again.")
        case .needsPerson:
            body = .init(
                key: "connection.lost.body.needsPerson",
                fallback: "The last attempt stopped at a question only you can answer.")
        }

        let detail: LostConnectionContent.Message?
        switch (reason, probeFailure) {
        case (.probeGaveUp, .timeout?):
            detail = .init(
                key: "connection.lost.detail.timeout",
                fallback: "The last checks got no answer in time.")
        case (.probeGaveUp, .connectionClosed?):
            detail = .init(
                key: "connection.lost.detail.closed",
                fallback: "The connection was closed by the server or by the network.")
        case (.probeGaveUp, .other?):
            detail = .init(
                key: "connection.lost.detail.other",
                fallback: "The last check ended in an error.")
        default:
            detail = nil
        }

        let hint: LostConnectionContent.Message?
        if !targetIsKnown {
            hint = .init(
                key: "connection.lost.hint.noSavedSession",
                fallback: "This connection was not saved, so reconnecting means filling the form in again.")
        } else if reason == .needsPerson {
            // Deliberately no "MacSCP keeps trying" hint even under
            // `.automatic`: this reason is exactly the case where it does
            // NOT keep trying (`ReconnectPlan.step`), and a hint promising
            // otherwise would be the surface contradicting the policy.
            hint = .init(
                key: "connection.lost.hint.stopped",
                fallback: "MacSCP is not retrying on its own until you have answered it.")
        } else {
            switch behaviour {
            case .automatic:
                hint = .init(
                    key: "connection.lost.hint.automatic",
                    fallback: "MacSCP keeps trying on its own, waiting longer between attempts.")
            case .onceThenAsk:
                hint = attempts == 0
                    ? .init(
                        key: "connection.lost.hint.onceUpcoming",
                        fallback: "MacSCP will try once on its own in a moment.")
                    : .init(
                        key: "connection.lost.hint.onceDone",
                        fallback: "MacSCP already tried once on its own.")
            case .offerOnly:
                hint = nil
            }
        }

        return LostConnectionContent(
            title: .init(key: "connection.lost.title", fallback: "Connection lost"),
            body: body,
            detail: detail,
            hint: hint,
            reconnectButton: targetIsKnown
                ? .init(key: "connection.lost.reconnect", fallback: "Reconnect") : nil,
            dismissButton: .init(
                key: "connection.lost.dismiss", fallback: "Back to the form"))
    }
}

/// What a failed-connect surface says, and which actions it offers
/// (failed-connect surface plan, Task 2). Shown instead of the ordinary
/// form after a connect attempt ends in `ConnectFailureKind.other` —
/// timeout, name resolution, refused — as opposed to `.needsPerson`, which
/// already has its own surface (a host-key or passphrase prompt) untouched
/// by this task.
///
/// Same structural shape as `LostConnectionContent`, and for the same
/// reason: only `(key, fallback)` message pairs and one flag decide what
/// shows, so there is no field a host name, a server message, or a raw
/// error string could occupy. The general message is safe by construction,
/// not by promise — the full technical text belongs to the details dialog
/// (`ConnectFailureDetailsSheet`, Task 3), never to this type; what this
/// type carries for that dialog is its LABEL and its headline, both catalog
/// keys like everything else here.
struct ConnectFailureContent: Equatable {
    struct Message: Equatable {
        let key: String
        let fallback: String
    }

    let title: Message
    /// The general sentence under the headline — and, for an ad-hoc
    /// attempt, the sentence that says what to do next.
    ///
    /// Two keys, chosen by the same `hasStoredSession` flag that decides
    /// `retryButton` and `editSessionButton` (maintainer decision,
    /// 2026-08-25, recorded in the design spec under the surface's own
    /// section). A stored-session failure keeps the plain line: Retry is
    /// right there and needs no explanation. An ad-hoc failure has no
    /// Retry at all, so its only way forward is a button labelled for
    /// EDITING — and a surface that offers that without saying why leaves
    /// someone hunting for a button that is not there.
    ///
    /// This deliberately softens the spec's original "one general message"
    /// rule. It is still one message per case and still a fixed catalog
    /// key: what varies is which of two fixed keys, never the text itself,
    /// so the structural property this whole type exists for is untouched.
    let body: Message
    /// Redial through the same connection path a fresh attempt uses.
    ///
    /// `nil` for an ad-hoc attempt (round 2, after review), for exactly the
    /// reason `editSessionButton` is: there is nothing stored to dial. The
    /// values an ad-hoc retry would use live on the form, and the form's
    /// own Connect button is the one place an ad-hoc dial happens — adding
    /// a second dial site to serve this button is the trade this whole
    /// surface exists to refuse. Round 1 offered the button anyway and had
    /// it hand the tab back to the form: no dial, no "Connecting…", which
    /// is precisely the behaviour the maintainer complained about, under a
    /// button named for the opposite. An action that cannot act is worse
    /// than an action that is not offered.
    let retryButton: Message?
    /// Returns an unsaved draft to its form. Saved sessions offer only the
    /// session editor, avoiding a second, ambiguous Edit action.
    let editButton: Message?
    /// The session editor — a durable change to what is stored. `nil` for
    /// an ad-hoc connection, which was never saved and so has nothing
    /// stored to edit.
    ///
    /// Mutually exclusive with the unsaved draft's `editButton`.
    let editSessionButton: Message?
    /// Close the tab. Always offered — the way off this surface, redial or
    /// not, the same as `LostConnectionContent.dismissButton`.
    let closeButton: Message
    /// Opens the details dialog (failed-connect surface plan, Task 3). The
    /// LABEL is a catalog key like every other string on the surface; the
    /// dialog's own body is the one raw text in this whole feature, and it
    /// is not carried by this type — see `ConnectFailureDetailText`.
    let detailsButton: Message
    /// Opens the diagnostics panel (design §1, this surface being the second
    /// of the tab's door). A field here rather than a literal in the view,
    /// for the same reason `detailsTitle` is one: a type that covers the text
    /// of a surface has to cover ALL of it, or the claim that this surface can
    /// only show a fixed, enumerated set of catalog keys — and therefore no
    /// host name, server message or typed value — is true only of the part
    /// that happens to live here. `theFailedSurfaceRendersNoStringOfItsOwn`
    /// caught exactly that when this label was first written as a literal in
    /// the view.
    ///
    /// The SAME key the other two doors use: one action, one label, in three
    /// places.
    let diagnoseButton: Message
    /// Opens the key-import sheet over the PEM key the failed attempt used,
    /// so MacSCP converts a copy of it (PEM private keys plan, Task 4).
    /// `nil` unless Core published a `ConnectFailureRemedy` — that is the
    /// one failure `ssh-keygen -p` fixes, and its payload is the only place
    /// a path to convert comes from.
    ///
    /// Optional for the same reason `retryButton` is: an action that cannot
    /// act is worse than an action that is not offered. Without a remedy
    /// there is no file to hand the sheet.
    let convertKeyButton: Message?
    /// Puts the in-place conversion command on the pasteboard, for the
    /// person who would rather run it themselves (PEM private keys plan,
    /// Task 4). `nil` under exactly the same condition as
    /// `convertKeyButton`.
    ///
    /// The COMMAND itself is not carried here and is not a display string:
    /// it comes from `SSHKeyConverter.inPlaceCommandLine(forKeyAt:)` and
    /// goes to `NSPasteboard`, never to a `Text` — which is what leaves this
    /// type's "a fixed, enumerated set of catalog keys and nothing else"
    /// claim intact. What this field holds is the button's LABEL, like every
    /// other field here.
    let copyCommandButton: Message?
    /// The details dialog's own headline. A field here rather than a
    /// literal in the dialog for the reason `LostConnectionContent`'s own
    /// doc comment gives for its two button labels: a type that covers the
    /// text of a surface has to cover all of it, or the claim that the keys
    /// are enumerable is true only of the part that happens to live here.
    let detailsTitle: Message
}

/// Builds `ConnectFailureContent` (failed-connect surface plan, Task 2)
/// from stored-session availability, a safe error category and an optional
/// key-conversion remedy. A plain
/// function over that one flag, the same move `LostConnectionPlan` and
/// `ConnectionSurfacePlan` made before it — nothing in this project renders
/// SwiftUI, so the decision of what shows has to live somewhere a test can
/// call, not inline in a view body.
enum ConnectFailurePlan {
    /// `hasStoredSession` is "this tab's failed attempt was dialed from a
    /// stored session" — resolved at the call site, the same place
    /// `LostConnectionPlan.content`'s `targetIsKnown` is.
    ///
    /// `remedy` is what Core published about the failure
    /// (`ConnectionViewModel.lastFailureRemedy`), and it is the whole of
    /// what the two conversion controls turn on. No default value, on
    /// purpose: a caller that forgot to pass it would silently render a
    /// surface without the remedy the layer below had already worked out,
    /// and the compiler is the cheapest place to catch that.
    static func content(
        hasStoredSession: Bool, remedy: ConnectFailureRemedy?, category: ConnectFailureCategory? = nil
    ) -> ConnectFailureContent {
        // Both, or neither: they are two ways to run the same conversion,
        // and a surface that offered one of them alone would be answering a
        // question nobody asked it.
        //
        // Matched on the CASE, not on `remedy != nil` (fix round 1, review
        // finding M1): `convertFailedKey(_:)` and
        // `copyConversionCommand(for:)` both open with
        // `guard case .convertKey(let path)? = …`, so a second remedy case
        // added to `ConnectFailureRemedy` would, under a nil-test, put two
        // buttons on the surface that silently return when pressed. The
        // compiler cannot catch that; this can.
        var convertKeyButton: ConnectFailureContent.Message?
        var copyCommandButton: ConnectFailureContent.Message?
        if case .convertKey? = remedy {
            convertKeyButton = .init(
                key: "connection.failed.convertKey", fallback: "Convert key…")
            copyCommandButton = .init(
                key: "connection.failed.copyCommand", fallback: "Copy command")
        }
        return ConnectFailureContent(
            title: category.flatMap { ConnectFailureMessages.messages(for: $0)?.title } ?? .init(
                key: "connection.failed.title", fallback: "No connection possible"),
            body: category.flatMap { ConnectFailureMessages.messages(for: $0)?.body } ?? (hasStoredSession
                ? .init(
                    key: "connection.failed.body",
                    fallback: "MacSCP could not connect to the host.")
                : .init(
                    key: "connection.failed.body.adHoc",
                    fallback: "MacSCP could not connect to the host. Edit the connection to "
                        + "check its settings and connect again.")),
            retryButton: hasStoredSession
                ? .init(key: "connection.failed.retry", fallback: "Try again") : nil,
            editButton: hasStoredSession ? nil : .init(key: "connection.failed.edit", fallback: "Edit"),
            editSessionButton: hasStoredSession
                ? .init(key: "connection.failed.editSession", fallback: "Edit session") : nil,
            closeButton: .init(key: "connection.failed.close", fallback: "Close"),
            detailsButton: .init(key: "connection.failed.details", fallback: "Details…"),
            diagnoseButton: .init(key: "diagnostics.menu", fallback: "Diagnose…"),
            convertKeyButton: convertKeyButton,
            copyCommandButton: copyCommandButton,
            detailsTitle: .init(
                key: "connection.failed.details.title", fallback: "Connection details"))
    }
}

/// Whether an unattended reconnect attempt is due, and when (connection-
/// liveness plan, Task 7) — the whole `offerOnly`/`onceThenAsk`/`automatic`
/// rule as a plain function, so `ReconnectRunner` below is left with
/// nothing but a sleep and a call.
///
/// The spacing itself is Core's (`ReconnectBackoff.delay(forAttempt:)`,
/// pinned by `ConnectionLivenessTests`): 5 seconds, doubling, capped at 60,
/// with no give-up limit. `.onceThenAsk` uses the same first delay rather
/// than firing immediately, so the two behaviours differ in how many
/// attempts they make and in nothing else.
enum ReconnectPlan {
    enum Step: Equatable {
        case wait(seconds: Int)
        case stop
    }

    /// `liveness` and `lost` are read together on purpose: an attempt is
    /// due only while the tab is actually sitting on the lost surface. A
    /// tab that is mid-attempt (`.connecting`), reconnected (`.connected`)
    /// or back at the form (`nil`) must not have a second attempt fired
    /// underneath it.
    static func step(
        liveness: ConnectionLiveness?, lost: LostConnection?,
        targetIsKnown: Bool, behaviour: ReconnectBehaviour
    ) -> Step {
        guard liveness == .lost, let lost, targetIsKnown else { return .stop }
        // The design spec's own exception (§3, restated in this task's
        // brief): even under `.automatic`, an attempt that ran into a
        // host-key decision or a key passphrase ends in the error view and
        // is NOT repeated in the background.
        guard lost.reason != .needsPerson else { return .stop }
        switch behaviour {
        case .offerOnly:
            return .stop
        case .onceThenAsk:
            guard lost.automaticAttempts < 1 else { return .stop }
        case .automatic:
            break
        }
        return .wait(seconds: ReconnectBackoff.delay(forAttempt: lost.automaticAttempts + 1))
    }
}

/// Mirrors `SessionTab.connectionViewModel.state` into `SessionTab
/// .liveness` while a connect attempt for THIS tab is running (connection-
/// liveness plan, Task 6) — mounted per tab in `ContentView.splitLayout`'s
/// `.background`, for every tab and not only the active one, for the same
/// reason `LivenessProbeRunner` is (see that type's own doc comment):
/// switching away from a connecting tab must not stop THAT tab's own dot
/// and surface from tracking its own attempt.
///
/// `tab.liveness` is the single fact Task 5's tab-strip dot and this task's
/// `ConnectionSurfacePlan` both read — this is the one place that drives it
/// INTO `.connecting`, so the dot and the surface cannot read two
/// independently-derived answers to "is this tab connecting right now".
///
/// `initial: true` (fix round 1, connection-liveness plan Task 6): without
/// it, `.onChange` only fires on a change witnessed AFTER this view has
/// mounted — a brand-new tab whose connect attempt starts before SwiftUI
/// gets a render pass to mount this view's row would have its very FIRST
/// `.connecting` transition missed entirely, leaving `tab.liveness` at
/// `nil` (dot blank, connecting surface never shown) until some LATER
/// transition happened to fire the observer. `initial: true` also
/// evaluates the closure once with the CURRENT value the moment the view
/// appears, closing that gap.
///
/// Two of `ConnectionViewModel.State`'s three cases write something here.
/// `.connecting` always means an attempt for this tab just started, and
/// always publishes `.connecting`. `.idle` is left alone: it is reached
/// both by a SUCCESSFUL dial (`ConnectionViewModel.connect()`'s own
/// success-path write) — where publishing `.connected` is `ContentView
/// .startSession`'s job, moments later, once the home-directory lookup
/// finishes, so resetting to `nil` here first would flash the form back for
/// that window — AND by `cancelConnecting()` (fix round 1: Cancel now
/// forces `state` to `.idle` too) — where `teardown(_:)`, called from the
/// SAME `onCancel` that calls `cancelConnecting()`, is already the thing
/// resetting `tab.liveness` to `nil`; this mirror does not need to race it.
/// `.failed` means the attempt just ended with nothing connected, and
/// resets to `nil` — but ONLY while `tab.session == nil`, and only while
/// this tab is not describing a dropped connection (see the Task 7
/// paragraph below). `.failed` is not exclusively a "just tried and failed
/// to connect" signal (`showFailure` is also how a validation refusal
/// unrelated to dialing — e.g. an empty save name — reaches this same
/// `state`), and this tab's own
/// `connectionViewModel` is never touched by anything while the tab IS
/// connected in today's App (the form that could touch it is not even
/// mounted then — see `ConnectionSurfacePlan`). Guarding on `tab.session`
/// rather than relying on that as an invariant is what keeps a latent path
/// from ever nilling a CONNECTED tab's liveness out from under it.
///
/// Task 7 added the one case this switch could not express before: a tab
/// whose connection was already LOST and whose failed attempt was the
/// reconnect from that surface. Clearing to `nil` there would drop the user
/// back onto the connection form the moment an unattended retry failed —
/// with the lost surface, its explanation and its Reconnect button gone,
/// and (under `.automatic`) the next retry still scheduled behind it. The
/// decision now lives in `ConnectAttemptLivenessPlan.write`, a plain
/// function, for the reason every other decision on this branch was pulled
/// out of a view body: nothing here can be rendered in a test.
struct ConnectAttemptLivenessMirror: View {
    let tab: SessionTab

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: tab.connectionViewModel.state, initial: true) { _, newState in
                // Liveness mirror write (connection-liveness plan, Task 7)
                switch ConnectAttemptLivenessPlan.write(
                    for: newState, hasSession: tab.session != nil,
                    describesLostConnection: tab.lostConnection != nil,
                    failureKind: tab.connectionViewModel.lastFailureKind)
                {
                case .connecting:
                    tab.liveness = .connecting
                    // A new attempt is what this tab is about now, so the
                    // previous one's failure stops speaking for it. Every
                    // dial reaches `.connecting` — the stored-session one
                    // and the form's own — so this one line is what keeps
                    // the failed surface from outliving the attempt that
                    // raised it, without a second clearing rule per path.
                    tab.connectFailure = nil
                case .lost(let reason):
                    // The reason is refreshed in the same step as the state
                    // it explains: an attempt that stopped at a host key or
                    // a passphrase must reach `.needsPerson` BEFORE
                    // `ReconnectRunner` re-reads this tab, or the very
                    // schedule that rule exists to stop would be decided on
                    // the reason of the attempt BEFORE it.
                    tab.lostConnection?.reason = reason
                    tab.liveness = .lost
                case .failedConnect:
                    // Failed-connect surface (failed-connect surface plan,
                    // Task 3). `liveness` still goes to `nil` — no
                    // connection exists, and the tab-strip dot's own
                    // reading of this tab is unchanged by this task — and
                    // the surface is chosen by `connectFailure` instead,
                    // which is why `ConnectionSurfacePlan` takes it as its
                    // own argument rather than deriving it from `liveness`.
                    tab.liveness = nil
                    // The origin comes from the ATTEMPT that failed (M3),
                    // not from a tab property written before the dial: a
                    // dial the form refused never became an attempt and so
                    // never wrote one. See `ConnectionViewModel
                    // .attemptOrigin`.
                    tab.connectFailure = ConnectFailure(
                        storedSessionID: tab.connectionViewModel.attemptOrigin)
                case .clear:
                    tab.liveness = nil
                    tab.connectFailure = nil
                case .leaveAlone:
                    break
                }
                // No origin to consume here (M3). It used to be cleared on
                // every state that was not `.connecting`, because it lived
                // on the tab and could outlive the dial that wrote it — a
                // refused dial changes no state, so that clear never ran
                // for the one case it was needed. `ConnectionViewModel
                // .attemptOrigin` is now assigned with the attempt itself
                // and replaced by the next one, so there is nothing left
                // here that could go stale.
            }
    }
}

/// What `ConnectAttemptLivenessMirror` writes for one `ConnectionViewModel
/// .State` (connection-liveness plan, Task 7) — the mirror's whole decision
/// as a plain function, so `Tests/macSCPAppKitTests/` can drive every
/// combination instead of a `.onChange` closure this project cannot render.
///
/// The three `State` cases, and why each answers as it does, are set out in
/// `ConnectAttemptLivenessMirror`'s own doc comment; the one case that is
/// new here is `.failed` on a tab that is describing a lost connection,
/// which goes back to `.lost` rather than clearing.
enum ConnectAttemptLivenessPlan {
    enum Write: Equatable {
        case connecting
        /// Back to the lost surface, with the reason this attempt earned.
        case lost(LostConnectionReason)
        /// Onto the failed-connect surface (failed-connect surface plan,
        /// Task 3): the attempt reached the wire and failed there, on a tab
        /// that has no session and no earlier connection to explain. Split
        /// out of `.clear`, which is where every failed first attempt used
        /// to land — and `.clear` means "show the form", which is exactly
        /// the fallback this surface replaces.
        case failedConnect
        case clear
        case leaveAlone
    }

    /// `failureKind` is `ConnectionViewModel.lastFailureKind`, read at the
    /// call site right after the state change that carries it. It is
    /// consulted only on the `.failed`-while-lost path: it is what turns
    /// "the reconnect failed" into "the reconnect stopped at something only
    /// a person can answer", which is the difference between a schedule
    /// that keeps running and one that stops (`ReconnectPlan.step`).
    static func write(
        for state: ConnectionViewModel.State, hasSession: Bool,
        describesLostConnection: Bool, failureKind: ConnectFailureKind?
    ) -> Write {
        switch state {
        case .connecting:
            return .connecting
        case .failed:
            guard !hasSession else { return .leaveAlone }
            guard describesLostConnection else {
                // Failed-connect surface (Task 3). `.other` is the design
                // spec's own boundary for it: a timeout, a name that did
                // not resolve, a refused connection. `.needsPerson` — an
                // unknown or changed host key, a missing passphrase, and
                // every pre-dial refusal, which are `.needsPerson` by
                // construction (see `ConnectFailureKind`) — keeps clearing
                // to the form, because the form is where the question that
                // stopped the attempt is actually asked and where its text
                // has always lived. A `nil` verdict is not a failed dial
                // this surface knows how to describe, and falls the same
                // way.
                return failureKind == .other ? .failedConnect : .clear
            }
            return .lost(failureKind == .needsPerson ? .needsPerson : .reconnectFailed)
        case .idle:
            return .leaveAlone
        }
    }
}

/// Runs the unattended part of the reconnect (connection-liveness plan,
/// Task 7) — mounted per tab in `ContentView.splitLayout`'s `.background`,
/// for every tab and not only the active one, the same shape and the same
/// reason as `LivenessProbeRunner` and `ConnectAttemptLivenessMirror`: a
/// background tab whose connection dropped is exactly the tab whose owner
/// is not watching it.
///
/// Holds no state of its own. WHETHER an attempt is due and after how long
/// is `ReconnectPlan.step`'s answer, HOW MANY attempts have run lives on
/// `SessionTab.lostConnection` (so it survives this view being torn down
/// and remounted between attempts, which `.task(id:)` guarantees will
/// happen), and the attempt itself is `ContentView.reconnect(_:)` —
/// which dials through the ordinary `connect(in:stored:)`, the same path a
/// sidebar connect takes. That last point is the load-bearing security
/// decision of this task and is guarded by `ReconnectWiringGuardTests`:
/// a second dial here would be a second place to forget TOFU.
///
/// The step is decided twice — once when the task starts, once after the
/// sleep. Not belt-and-braces: `RunKey` cannot contain whether the stored
/// session still exists (that lives in `SessionListViewModel`, and is
/// resolved through `targetIsKnown` at decision time), so a session deleted
/// during the wait would otherwise be redialled by a schedule that was
/// decided before it went away.
struct ReconnectRunner: View {
    let tab: SessionTab
    let settingsStore: SettingsStore
    /// Whether this tab's dropped connection still names a stored session
    /// that is in the list right now — a closure, not a value, so it is
    /// answered when the decision is made rather than when this view was
    /// last rendered.
    let targetIsKnown: (SessionTab) -> Bool
    let onAttempt: (SessionTab) -> Void

    /// Restarts the task whenever anything the schedule was decided from
    /// changes: the tab leaving (or re-entering) `.lost`, an attempt having
    /// been counted, and the setting itself — so changing the behaviour in
    /// Settings applies to a tab already sitting on the lost surface.
    private struct RunKey: Equatable {
        let liveness: ConnectionLiveness?
        let lost: LostConnection?
        let behaviour: ReconnectBehaviour
    }

    private var runKey: RunKey {
        RunKey(
            liveness: tab.liveness, lost: tab.lostConnection,
            behaviour: settingsStore.reconnectBehaviour)
    }

    private var step: ReconnectPlan.Step {
        ReconnectPlan.step(
            liveness: tab.liveness, lost: tab.lostConnection,
            targetIsKnown: targetIsKnown(tab),
            behaviour: settingsStore.reconnectBehaviour)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: runKey) {
                // Reconnect schedule (connection-liveness plan, Task 7)
                guard case .wait(let seconds) = step else { return }
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, case .wait = step else { return }
                // Counted BEFORE the dial, and in the same synchronous
                // step: the count is of attempts STARTED. Incrementing
                // afterwards would let a slow attempt be scheduled a second
                // time on the old count, and would make `.onceThenAsk`
                // depend on how long a dial takes.
                tab.lostConnection?.automaticAttempts += 1
                onAttempt(tab)
            }
    }
}

/// The width the split view actually gave the sidebar, carried up from the
/// sidebar's own background to `SidebarWidthRecorder` beside the split
/// container.
///
/// A preference rather than a second piece of view state for one reason:
/// the recorder has to see this width and the container's width as they
/// were in ONE layout pass. Two `@State` values, each written by its own
/// reader, can be read a pass apart — and a container width from before a
/// window resize next to a sidebar width from after it is exactly the pair
/// that looks like a drag.
private struct SidebarMeasuredWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    /// The sidebar publishes exactly one value; this exists because the
    /// protocol requires it. Last non-zero wins, so a pass that measures
    /// nothing cannot overwrite a real measurement with 0.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// One layout pass, as the two widths a width change has to be judged by.
private struct SidebarWidthSample: Equatable {
    let container: CGFloat
    let sidebar: CGFloat
}

/// Writes the sidebar's width back to `SettingsStore` after the user drags
/// the split divider.
///
/// Measured rather than bound, because `HSplitView` reports no drag: the
/// divider moves the sidebar's width, and the only place that width can be
/// read is the layout it produced. Which means everything else that moves
/// the sidebar's width arrives here looking identical to a drag — and one
/// of those is destructive. A pristine window (one unconnected tab) holds
/// its content to 700 points against a 500-point detail minimum, leaving
/// 200 for the sidebar, well under the 340 `SettingsStore
/// .sidebarWidthRange` allows. Disconnecting the last tab shrinks the
/// window to exactly that; a recorder that wrote down every width it saw
/// would take a sidebar the user had dragged to 340 and store 200 in its
/// place, having been told nothing by the user at all.
///
/// So a width is only written when the container it sits in is the same
/// width it was — a divider drag moves the sidebar inside a container that
/// does not move, and every squeeze comes from a container that does. The
/// comparison is between SETTLED samples, not between consecutive ones:
/// during a window resize the two widths change in whatever order SwiftUI
/// delivers them, and a pair caught mid-resize can show a still-old
/// container beside an already-squeezed sidebar. Waiting for the whole
/// thing to stop and comparing the endpoints has no such ordering to get
/// wrong.
///
/// The first settled sample after this view is built is never written: it
/// is the width the window opened at, which is where it came from.
///
/// Disk cost: `SettingsStore` writes the whole settings.json on every
/// assignment, and a divider drag produces a layout pass per mouse point.
/// The settle interval is what keeps those apart — a drag costs ONE write,
/// when the pointer comes to rest, not one per point crossed.
private struct SidebarWidthRecorder: View {
    let settingsStore: SettingsStore
    let sample: SidebarWidthSample

    /// The last sample that survived the settle interval — the baseline the
    /// next settled one is judged against. `nil` until the first one
    /// settles, which is why the opening width is never written back.
    @State private var settled: SidebarWidthSample?

    /// Long enough to sit out a drag (the pointer keeps moving, so the task
    /// keeps restarting) and a window resize, short enough that letting go
    /// of the divider and quitting straight afterwards still saves the
    /// width.
    private static let settleSeconds = 0.4

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: sample) {
                try? await Task.sleep(for: .seconds(Self.settleSeconds))
                guard !Task.isCancelled else { return }
                // A pass that measured nothing is not a sample at all: let
                // it become the baseline and the real measurement arriving
                // after it would read as the user having dragged the
                // sidebar down to nothing.
                guard sample.sidebar > 0 else { return }
                let previous = settled
                settled = sample
                guard let previous, previous.container == sample.container else { return }
                let width = Int(sample.sidebar.rounded())
                guard width != settingsStore.sidebarWidth else { return }
                settingsStore.sidebarWidth = width
            }
    }
}

/// The lost-connection surface (connection-liveness plan, Task 7): what
/// happened, and the way back. Shown instead of `ConnectionFormView` while
/// `ConnectionSurfacePlan.surface(for:hostKeyPromptPending:connectAttemptFailed:)`
/// answers
/// `.lost`.
///
/// Every string on it comes from `LostConnectionContent`, which holds
/// catalog keys and nothing else — see that type's own doc comment for why
/// the design spec's "no secret, no user-typed value" rule is a property of
/// the type here rather than a rule someone has to remember. In particular
/// this surface does NOT show the host, the account, the failure text the
/// server sent, or anything from the form.
private struct LostConnectionView: View {
    let content: LostConnectionContent
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.string(content.title.key, content.title.fallback))
                .font(.title2.bold())
            Text(L10n.string(content.body.key, content.body.fallback))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail = content.detail {
                Text(L10n.string(detail.key, detail.fallback))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let hint = content.hint {
                Text(L10n.string(hint.key, hint.fallback))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                if let reconnect = content.reconnectButton {
                    Button(L10n.string(reconnect.key, reconnect.fallback), action: onReconnect)
                        .buttonStyle(.borderedProminent)
                }
                Button(
                    L10n.string(content.dismissButton.key, content.dismissButton.fallback),
                    action: onDismiss)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .buttonStyle(.bordered)
    }
}

/// The failed-connect surface (failed-connect surface plan, Task 3): the
/// attempt did not get through, and what can be done about it. Shown
/// instead of `ConnectionFormView` while `ConnectionSurfacePlan
/// .surface(for:hostKeyPromptPending:connectAttemptFailed:)` answers
/// `.failed`.
///
/// The maintainer's own words for why it exists: after a real timeout
/// against an unreachable host, the connection form simply came back, and
/// being handed the entry mask again reads as "nothing happened" rather
/// than as an answer.
///
/// Every string on the surface itself comes from `ConnectFailureContent`,
/// which holds catalog keys and nothing else — the same property
/// `LostConnectionView` has, for the same reason, and
/// `ReconnectWiringGuardTests` scans this body to keep it true. The one
/// piece of text that is NOT a catalog key is the technical message, and it
/// is not on this surface: it lives behind the details control, in a dialog
/// of its own (`ConnectFailureDetailsSheet`, in its own file so that this
/// view cannot read the string at all), which is the maintainer's
/// decision — a general sentence here, everything precise one click away
/// for debugging.
private struct ConnectFailureView: View {
    let content: ConnectFailureContent
    /// The technical text, or `nil` when the layer below published none —
    /// in which case the details control is not offered at all rather than
    /// opening an empty dialog.
    ///
    /// An opaque `ConnectFailureDetailText`, not a `String`, and that is
    /// the whole point: this view tests it for `nil` and hands it to the
    /// dialog. Naming its string here does not compile, and reflecting it
    /// here — which does compile, and used to print the server's own
    /// message — now yields a placeholder. See that type's own doc comment
    /// for where exactly that boundary runs, and for why a `String?` here,
    /// which is what round 1 had, gave this surface the structural
    /// guarantee and the raw server text side by side.
    let details: ConnectFailureDetailText?
    let onRetry: () -> Void
    let onEdit: () -> Void
    let onEditSession: () -> Void
    /// Opens the diagnostics panel for this tab. It opens it and nothing
    /// more: the probes run when the user presses the panel's own button
    /// (decision of 2026-09-02), so this surface starts no dial of its own.
    let onDiagnose: () -> Void
    /// Opens the key-import sheet over the PEM key that failed, which is
    /// where the conversion and the redial happen (PEM private keys plan,
    /// Task 4). Offered only when `content.convertKeyButton` is non-nil.
    let onConvertKey: () -> Void
    /// Copies the in-place `ssh-keygen -p` command line to the pasteboard.
    /// The command is built in `ContentView`, from `SSHKeyConverter`; this
    /// view never sees it, which is why the surface still renders nothing
    /// but catalog keys.
    let onCopyCommand: () -> Void
    let onClose: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.string(content.title.key, content.title.fallback))
                .font(.title2.bold())
            Text(L10n.string(content.body.key, content.body.fallback))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if let retry = content.retryButton {
                    Button(L10n.string(retry.key, retry.fallback), action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
                if let edit = content.editButton {
                    Button(L10n.string(edit.key, edit.fallback), action: onEdit)
                }
                if let editSession = content.editSessionButton {
                    Button(
                        L10n.string(editSession.key, editSession.fallback),
                        action: onEditSession)
                }
                Button(
                    L10n.string(content.closeButton.key, content.closeButton.fallback),
                    action: onClose)
            }
            // Beside the row of actions rather than in it: Retry/Edit session/Close
            // are the ways ON from a failed connect, and this is the way to
            // find out why it failed — the same secondary weight the details
            // link below carries. No gate, and deliberately: every probe is
            // measured fresh, so there is no state in which asking is
            // meaningless.
            HStack(spacing: 12) {
                Button(
                    L10n.string(content.diagnoseButton.key, content.diagnoseButton.fallback),
                    action: onDiagnose)
                // The conversion pair, in the secondary row rather than in
                // the row of ways ON: converting a key is a remedy for one
                // particular failure, not a way off this surface, and it is
                // offered at all only when the layer below said this
                // failure has one.
                if let convert = content.convertKeyButton {
                    Button(L10n.string(convert.key, convert.fallback), action: onConvertKey)
                }
                if let copyCommand = content.copyCommandButton {
                    Button(
                        L10n.string(copyCommand.key, copyCommand.fallback),
                        action: onCopyCommand)
                }
            }
            if details != nil {
                Button(
                    L10n.string(content.detailsButton.key, content.detailsButton.fallback)
                ) {
                    showsDetails = true
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .buttonStyle(.bordered)
        .sheet(isPresented: $showsDetails) {
            if let details {
                ConnectFailureDetailsSheet(
                    title: content.detailsTitle, details: details,
                    onClose: { showsDetails = false })
            }
        }
    }
}

/// "Connecting…" with a Cancel control (connection-liveness plan, Task 6) —
/// shown instead of `ConnectionFormView` while `ConnectionSurfacePlan
/// .surface(for:hostKeyPromptPending:connectAttemptFailed:)` answers
/// `.connecting`. The design
/// spec's own framing for this surface
/// (`docs/superpowers/specs/2026-08-21-connection-state-design.md` §4):
/// the connection attempt becomes a cancellable task on the same tab area,
/// so the rest of the window — other tabs, the sidebar once this one's own
/// dial ends — stays usable instead of the tab looking like a dead modal
/// with nothing to click.
///
/// The headline has its OWN catalog key (`connection.connecting.title`,
/// fix round 1) rather than reusing the tab-strip dot's tooltip key
/// (`tabs.liveness.connectingHelp`, Task 5): the two read the same today,
/// but a tooltip and a headline are different UI roles that can legitimately
/// need different wording later, and sharing one key would silently change
/// this surface's text the next time someone edits the dot's tooltip for
/// its OWN reasons.
private struct ConnectingAttemptView: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("connection.connecting.title", "Connecting…"))
                .font(.title2.bold())
            Text(L10n.string(
                "connection.connecting.body",
                "MacSCP is waiting for the host to respond."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.string("common.cancel", "Cancel"), action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
