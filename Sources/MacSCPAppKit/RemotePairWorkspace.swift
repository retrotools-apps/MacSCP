import AppKit
import SwiftUI
import macSCPCore

/// Two remote panes backed by their original tabs. Only presentation is combined.
struct RemotePairWorkspace: View {
    let pair: RemotePanePair
    let left: SessionTab
    let right: SessionTab
    let settings: SettingsStore
    let onOpenFile: (RemoteFileItem, SessionTab, BrowserSession) -> Bool
    let onDropURLs: ([URL], SessionTab, BrowserSession) -> Void
    let onPromise: (RemoteFileItem, SessionTab, BrowserSession) -> NSPasteboardWriting?
    var availableTargets: ((SessionTab) -> [CrossSessionTarget])? = nil
    var onTransferToSession: (([RemoteFileItem], SessionTab, BrowserSession, CrossSessionTarget) -> Void)? = nil
    private var activeSide: BrowserPaneSide { left.commanderActiveSide }

    private var onServer: Bool {
        RemoteSessionTransfer.sameEndpoint(left.connectionViewModel.lastConnectedConfig,
                                           right.connectionViewModel.lastConnectedConfig)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(onServer ? L10n.string("remotePair.serverRoute", "Copies on the server")
                    : L10n.string("remotePair.route", "Transfers via this Mac"),
                      systemImage: onServer ? "server.rack" : "laptopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { pair.detach() } label: {
                    Label(L10n.string("remotePair.unlink", "Local / remote view"), systemImage: "rectangle.split.2x1")
                }
                .controlSize(.small)
                .help(L10n.string("remotePair.unlinkHelp", "Separate the views without disconnecting either server"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            HSplitView {
                column(left, other: right, position: .local)
                column(right, other: left, position: .remote)
            }
        }
        .frame(minWidth: 560, minHeight: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func column(_ owner: SessionTab, other: SessionTab, position: BrowserPaneSide) -> some View {
        if let session = owner.session {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(owner.displayTitle).font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(owner.displayTitle)
                    Spacer(minLength: 4)
                    Button { _ = pair.transfer(session.remote.selectedItems, from: owner) } label: {
                        Image(systemName: position == .local ? "arrow.right" : "arrow.left")
                    }
                    .controlSize(.small)
                    .disabled(pair.liveTabs == nil || session.remote.state != .loaded || BrowserKeyCommand.resolve(key: .space,
                        selection: session.remote.selectedItems, side: .remote) == nil)
                    .help(L10n.string("remotePair.copy", "Copy to the other server"))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                pane(owner, other: other, session: session, position: position)
                    .layoutPriority(1)
                if let message = owner.remoteTransferErrorMessage ?? owner.editErrorMessage {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                        Spacer()
                        Button {
                            owner.remoteTransferErrorMessage = nil
                            owner.editErrorMessage = nil
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help(L10n.string("common.close", "Close"))
                    }.padding(6)
                }
                if owner.transfersPanelVisible {
                    TransferQueueBar(viewModel: owner.transferQueue, sessionName: owner.titleName, settingsStore: settings)
                }
            }
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: owner.transferQueue.items.count) { oldCount, newCount in
                if newCount > oldCount { owner.transfersPanelVisible = true }
            }
            .transferConflictSheet(bridge: owner.conflictBridge)
            .task(id: session.id) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(settings.autoRefreshIntervalSeconds))
                    guard !Task.isCancelled, pair.liveTabs != nil else { return }
                    if settings.autoRefreshEnabled { await session.remote.refreshQuietly() }
                }
            }
        }
    }

    private func pane(_ owner: SessionTab, other: SessionTab, session: BrowserSession,
                      position: BrowserPaneSide) -> some View {
        BrowserPane(fileWindows: owner.fileWindows, title: L10n.string("browser.paneRemote", "Remote"),
            tint: DesignTokens.remoteBlue, softTint: DesignTokens.remoteSoft,
            viewModel: session.remote, side: .remote, transferGroupID: pair.id,
            transferPaneSide: position, isActivePane: activeSide == position,
            onActivatePane: { left.commanderActiveSide = position },
            onDropURLs: { urls in
                guard pair.liveTabs != nil else { return }
                onDropURLs(urls, owner, session)
            },
            onOpenFile: { onOpenFile($0, owner, session) },
            fileSystem: session.remoteFS,
            pasteboardWriter: { item in item.kind == .file ? onPromise(item, owner, session) : nil },
            onMenuAction: { entry, selection in
                guard pair.liveTabs != nil else { return }
                switch entry {
                case .transferToOtherPane: _ = pair.transfer(selection, from: owner)
                case .transferToSession(let target):
                    if let onTransferToSession {
                        onTransferToSession(selection, owner, session, target)
                        return
                    }
                    guard target.id == other.id else { return }
                    _ = RemoteSessionTransfer.enqueue(selection, from: owner, to: other,
                        directory: target.remotePath, expectedSourceSessionID: session.id)
                case .copyPath:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selection.map(\.path).joined(separator: "\n"), forType: .string)
                case .openInEditor:
                    if let item = selection.first { _ = onOpenFile(item, owner, session) }
                default: break // Pane-local actions are handled by BrowserPane itself.
                }
            },
            crossSessionTargets: {
                availableTargets?(owner) ?? CrossSessionTargets.targets(excluding: owner.id, in: [owner, other])
            },
            destinationScope: {
                guard let remote = other.session?.remote else { return .ordinary }
                return BrowserScope(rootIsContainerList: false, currentPath: remote.currentPath)
            },
            visibleColumns: settings.visibleColumns, checksumAlgorithm: settings.checksumAlgorithm,
            checksumLedger: owner.checksumLedgerBinding(for: .remote, in: session),
            supportsChecksum: ChecksumAvailability.isOffered(for: .ssh),
            supportsPermissions: PermissionsAvailability.isOffered(for: .ssh))
    }
}
