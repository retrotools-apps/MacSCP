import Foundation
import macSCPCore

/// Different servers stream through this Mac. Identical SSH routes copy on the
/// server through the existing connection, without credential delegation.
@MainActor
enum RemoteSessionTransfer {
    @discardableResult
    static func enqueue(_ selection: [RemoteFileItem], from source: SessionTab, to target: SessionTab,
                        directory: String, expectedSourceSessionID: UUID? = nil) -> Bool {
        guard source !== target, !source.isDisconnecting, !target.isDisconnecting,
              let input = source.session, let output = target.session,
              expectedSourceSessionID == nil || expectedSourceSessionID == input.id,
              BrowserScope(rootIsContainerList: output.remoteFS.rootIsContainerList,
                           currentPath: directory).acceptsIncomingFiles else { return false }
        source.remoteTransferErrorMessage = nil
        let onServer = sameEndpoint(source.connectionViewModel.lastConnectedConfig, target.connectionViewModel.lastConnectedConfig)
        if onServer,
           selection.contains(where: { overlapsSource($0, destinationDirectory: directory) }) {
            source.remoteTransferErrorMessage = L10n.string("remotePair.sameLocation",
                "Cannot copy a file onto itself or a folder into itself on the same server.")
            return false
        }
        var enqueued = false
        let outputID = output.id
        for item in selection where item.kind != .symlink && !item.isBucket {
            let completed: @MainActor () async -> Void = { [weak target, weak remote = output.remote] in
                // Do not refresh a disconnected or replaced session.
                guard let target, target.session?.id == outputID, !target.isDisconnecting else { return }
                await remote?.refresh()
            }
            let fileSource: any RemoteFileSystem
            if onServer {
                guard let copier = input.remoteFS as? any ServerSideFileCopying else {
                    source.remoteTransferErrorMessage = L10n.string("remotePair.serverCopyUnavailable",
                        "Server-side copying is unavailable for this connection.")
                    return false
                }
                fileSource = ServerSideCopyFileSystem(base: copier, sourceDirectory: item.path,
                    destinationDirectory: directory, name: item.name)
            } else {
                fileSource = input.remoteFS
            }
            let destination = CrossBackendTarget(name: target.displayTitle, kind: target.connectionViewModel.kind)
            if item.kind == .directory {
                source.transferQueue.enqueueTree(directoryName: item.name, direction: .upload,
                    source: fileSource, sourceDirectory: item.path, destination: output.remoteFS,
                    destinationDirectory: directory, onCompleted: completed, destinationTabID: target.id,
                    crossRemote: true, crossBackendTarget: destination)
            } else {
                source.transferQueue.enqueue(fileName: item.name, direction: .upload,
                    source: fileSource, sourcePath: item.path, destination: output.remoteFS,
                    destinationDirectory: directory, onCompleted: completed, destinationTabID: target.id,
                    crossRemote: true, crossBackendTarget: destination)
            }
            enqueued = true
        }
        if enqueued { source.transfersPanelVisible = true }
        return enqueued
    }

    /// Compare route metadata only, never secrets. Identical private target names
    /// behind DIFFERENT jumps must not be mistaken for the same file system.
    static func sameEndpoint(_ first: SSHConnectionConfig?, _ second: SSHConnectionConfig?) -> Bool {
        guard let first, let second else { return false }
        return first.host.lowercased() == second.host.lowercased() && first.port == second.port
            && first.username == second.username && first.tlsTunnel == second.tlsTunnel
            && first.jump?.host.lowercased() == second.jump?.host.lowercased()
            && first.jump?.port == second.jump?.port && first.jump?.username == second.jump?.username
            && first.jump?.tlsTunnel == second.jump?.tlsTunnel
    }

    static func overlapsSource(_ item: RemoteFileItem, destinationDirectory: String) -> Bool {
        let source = RemotePath.normalizedAbsolute(item.path)
        let target = RemotePath.normalizedAbsolute(RemotePath.join(destinationDirectory, item.name))
        return source == target || (item.kind == .directory && target.hasPrefix(source == "/" ? "/" : source + "/"))
    }
}
