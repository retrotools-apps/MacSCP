import AppKit
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore
@testable import MacSCPAppKit

@MainActor
@Suite("Paired remote panes", .timeLimit(.minutes(1)))
struct RemotePanePairTests {
    @Test func pairingKeepsTheConnectionsAndUnlinkingDoesNotDisconnect() throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let leftID = fixture.left.session?.id
        let rightID = fixture.right.session?.id
        let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
        #expect(pair.liveTabs?.left === fixture.left)
        #expect(pair.liveTabs?.right === fixture.right)
        #expect(fixture.left.remotePair === fixture.right.remotePair)
        pair.detach()
        #expect(fixture.left.remotePair == nil)
        #expect(fixture.right.remotePair == nil)
        #expect(fixture.left.session?.id == leftID)
        #expect(fixture.right.session?.id == rightID)
        #expect(pair.liveTabs == nil)
    }

    @Test func onlyDistinctLiveSSHConnectionsCanBePaired() throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        #expect(RemotePanePair.join(left: fixture.left, right: fixture.left) == nil)
        fixture.right.isDisconnecting = true
        #expect(RemotePanePair.join(left: fixture.left, right: fixture.right) == nil)
        fixture.right.isDisconnecting = false
        fixture.right.connectionViewModel.kind = .s3
        #expect(RemotePanePair.join(left: fixture.left, right: fixture.right) == nil)
        fixture.right.connectionViewModel.kind = .ssh
        fixture.right.session = nil
        #expect(RemotePanePair.join(left: fixture.left, right: fixture.right) == nil)
    }

    @Test func reconnectingEitherSideInvalidatesTheOldPair() throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
        fixture.attach(fixture.right, path: fixture.rightDirectory.path)
        #expect(pair.liveTabs == nil)
        #expect(!pair.transfer([], from: fixture.left))
        #expect(fixture.left.transferQueue.items.isEmpty)
    }

    @Test(arguments: [false, true])
    func copiesFilesAndDirectoriesInBothDirections(reverse: Bool) async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let source = reverse ? fixture.right : fixture.left
        let target = reverse ? fixture.left : fixture.right
        let input = try #require(source.session)
        let output = try #require(target.session)
        let root = URL(fileURLWithPath: input.remote.currentPath)
        let nested = root.appendingPathComponent("folder/sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = Data((0..<(TransferChunk.size * 3 + 17)).map { UInt8($0 % 251) })
        try payload.write(to: root.appendingPathComponent("file.bin"))
        try Data("nested content".utf8).write(to: nested.appendingPathComponent("nested.txt"))
        await input.remote.load()
        let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
        #expect(pair.transfer(input.remote.items, from: source))
        // Unlinking must not cancel jobs or retarget them to the local pane.
        pair.detach()
        try await pollUntil("paired copies finish") {
            !source.transferQueue.items.isEmpty && source.transferQueue.items.allSatisfy { $0.status.isTerminal }
                && !source.transferQueue.hasActiveItems(destinationTabID: target.id)
        }
        #expect(source.transferQueue.items.allSatisfy { $0.status == .finished })
        #expect(source.transferQueue.items.allSatisfy { $0.crossRemote && $0.destinationTabID == target.id })
        #expect(source.transferQueue.items.allSatisfy { $0.direction == .upload })
        #expect(target.transferQueue.items.isEmpty)
        let destination = URL(fileURLWithPath: output.remote.currentPath)
        #expect(try Data(contentsOf: destination.appendingPathComponent("file.bin")) == payload)
        #expect(try Data(contentsOf: destination.appendingPathComponent("folder/sub/nested.txt")) == Data("nested content".utf8))
        #expect(fixture.left.session?.id != nil && fixture.right.session?.id != nil)
    }

    @Test func nativeRemoteDragUsesPhysicalSlotsButKeepsRemoteActions() async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let payload = Data("dragged remote bytes".utf8)
        let sourceURL = fixture.leftDirectory.appendingPathComponent("drag.bin")
        try payload.write(to: sourceURL)
        let item = try await fixture.left.session!.remoteFS.stat(path: sourceURL.path)
        let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
        let source = RemoteFileTableView.Coordinator(onOpen: { _ in }, onSelect: { _ in }, side: .remote)
        let target = RemoteFileTableView.Coordinator(onOpen: { _ in }, onSelect: { _ in }, side: .remote)
        source.items = [item]
        source.directoryPath = fixture.leftDirectory.path
        target.directoryPath = fixture.rightDirectory.path
        source.transferGroupID = pair.id
        target.transferGroupID = pair.id
        source.transferPaneSide = .local
        target.transferPaneSide = .remote
        source.onMenuAction = { action, selection in
            #expect(action == .transferToOtherPane)
            #expect(pair.transfer(selection, from: fixture.left))
        }
        source.beginPaneDrag(rows: IndexSet(integer: 0))
        #expect(target.canReceiveDrag(from: source))
        #expect(target.receiveDrag(from: source))
        #expect(fixture.left.transferQueue.items.isEmpty)
        await target.dropPublicationTask?.value
        try await pollUntil("native paired drag copy finishes") { fixture.left.transferQueue.items.first?.status.isTerminal == true }
        #expect(fixture.left.transferQueue.items.first?.status == .finished)
        #expect(try Data(contentsOf: fixture.rightDirectory.appendingPathComponent("drag.bin")) == payload)
        source.beginPaneDrag(rows: IndexSet(integer: 0))
        target.transferGroupID = UUID()
        #expect(!target.canReceiveDrag(from: source))
        target.transferGroupID = pair.id
        target.transferPaneSide = .local
        #expect(!target.canReceiveDrag(from: source))
    }

    @Test func centerAndEdgesRemainDifferentGestures() {
        #expect(RemotePairDropZone.isCenter(x: 80, width: 160))
        #expect(!RemotePairDropZone.isCenter(x: 10, width: 160))
        #expect(!RemotePairDropZone.isCenter(x: 150, width: 160))
        #expect(!RemotePairDropZone.isCenter(x: .nan, width: 160))
        #expect(!RemotePairDropZone.isCenter(x: 0, width: 0))
    }

    @Test func sameServerCopiesCannotOverwriteTheirOwnSource() async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        func connectedTab() async throws -> SessionTab {
            let model = ConnectionViewModel(connector: { _, _ in LocalFileSystem() })
            model.host = "same-server.invalid"
            model.username = "fixture-user"
            model.authChoice = .agent
            let fs = try #require(await model.connect())
            let tab = SessionTab(connectionViewModel: model, certificateBridge: CertificatePromptBridge(),
                limiter: BandwidthLimiter(), maxConcurrent: 2)
            fixture.attach(tab, path: fixture.leftDirectory.path, fs: fs)
            return tab
        }
        let source = try await connectedTab(), target = try await connectedTab()
        let payload = Data("must remain intact".utf8)
        let file = fixture.leftDirectory.appendingPathComponent("original.txt")
        try payload.write(to: file)
        let item = try await source.session!.remoteFS.stat(path: file.path)
        let pair = try #require(RemotePanePair.join(left: source, right: target))
        #expect(!pair.transfer([item], from: source))
        #expect(source.remoteTransferErrorMessage != nil)
        #expect(source.transferQueue.items.isEmpty)
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test func overlapChecksRespectFolderBoundariesAndJumpRoutes() throws {
        let directory = RemoteFileItem(name: "folder", path: "/home/folder", kind: .directory)
        #expect(RemoteSessionTransfer.overlapsSource(directory, destinationDirectory: "/home"))
        #expect(RemoteSessionTransfer.overlapsSource(directory, destinationDirectory: "/home/folder/child"))
        #expect(!RemoteSessionTransfer.overlapsSource(directory, destinationDirectory: "/home/folder-sibling"))
        let first = try SSHConnectionConfig(host: "private-server", username: "user", auth: .agent,
            jump: .init(host: "first-bastion", username: "jump-user", auth: .agent))
        let second = try SSHConnectionConfig(host: "private-server", username: "user", auth: .agent,
            jump: .init(host: "second-bastion", username: "jump-user", auth: .agent))
        #expect(RemoteSessionTransfer.sameEndpoint(first, first))
        #expect(!RemoteSessionTransfer.sameEndpoint(first, second))
        #expect(!RemoteSessionTransfer.sameEndpoint(nil, nil))
    }
}

@MainActor
struct RemotePairTestFixture {
    let root: URL
    let leftDirectory: URL
    let rightDirectory: URL
    let left: SessionTab
    let right: SessionTab

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macscp-pair-\(UUID().uuidString)")
        leftDirectory = root.appendingPathComponent("left")
        rightDirectory = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: leftDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDirectory, withIntermediateDirectories: true)
        left = Self.tab()
        right = Self.tab()
        attach(left, path: leftDirectory.path)
        attach(right, path: rightDirectory.path)
        left.titleName = "Source server"
        right.titleName = "Destination server"
    }

    static func tab() -> SessionTab {
        SessionTab(connectionViewModel: ConnectionViewModel(connector: { _, _ in
            Issue.record("Pairing must not open another connection")
            throw CancellationError()
        }), certificateBridge: CertificatePromptBridge(), limiter: BandwidthLimiter(), maxConcurrent: 2)
    }

    func attach(_ tab: SessionTab, path: String, fs: any RemoteFileSystem = LocalFileSystem()) {
        let id = UUID()
        tab.session = BrowserSession(id: id, localFS: LocalFileSystem(), remoteFS: fs,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fs, startPath: path),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in throw CancellationError() }),
            editManager: EditSessionManager(sessionID: id, queue: tab.transferQueue), homePath: path)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
