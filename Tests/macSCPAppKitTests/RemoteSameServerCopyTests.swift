import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore
@testable import MacSCPAppKit

@MainActor
@Suite("Remote Commander copies", .timeLimit(.minutes(2)))
struct RemoteSameServerCopyTests {
    @Test(arguments: [false, true]) func filesAndTreesNeverFallBackToClientPayload(serverRefuses: Bool) async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let base = LocalFileSystem()
        let spy = ServerCopySpy(base: base, refusesCopy: serverRefuses)
        let left = try await tab(fs: spy, path: fixture.leftDirectory.path, fixture: fixture)
        let right = try await tab(fs: base, path: fixture.rightDirectory.path, fixture: fixture)
        let file = fixture.leftDirectory.appendingPathComponent("file ' with spaces.txt")
        let folder = fixture.leftDirectory.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = Data("server-side payload".utf8)
        try payload.write(to: file)
        try payload.write(to: folder.appendingPathComponent("child.txt"))
        let pair = try #require(RemotePanePair.join(left: left, right: right))
        let items = try await [base.stat(path: file.path), base.stat(path: folder.path)]
        #expect(pair.transfer(items, from: left))
        try await pollUntil("server-side file and tree finish") {
            left.transferQueue.items.count == 2 && left.transferQueue.items.allSatisfy { $0.status.isTerminal }
        }
        #expect(left.transferQueue.items.allSatisfy {
            if serverRefuses { if case .failed = $0.status { return true }; return false }
            return $0.status == .finished
        })
        #expect(await spy.copies == 2)
        #expect(await spy.payloadCalls == 0)
        #expect(try Data(contentsOf: file) == payload)
        if serverRefuses {
            #expect(!FileManager.default.fileExists(atPath: fixture.rightDirectory.appendingPathComponent(file.lastPathComponent).path))
            return
        }
        #expect(try Data(contentsOf: fixture.rightDirectory.appendingPathComponent(file.lastPathComponent)) == payload)
        #expect(try Data(contentsOf: fixture.rightDirectory.appendingPathComponent("tree/child.txt")) == payload)
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func twoSSHConnectionsCopyWithinOneHostWithoutClientPayload() async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let known = KnownHostsStore(directory: fixture.root.appendingPathComponent("known"))
        let config = try SSHConnectionConfig(host: "127.0.0.1", port: 2222, username: "testuser", auth: .password("testpass"))
        let first = try await CitadelFileSystem.connect(config: config, connectTimeout: .seconds(15),
            knownHosts: known, onUnknownHostKey: .asking { _ in true })
        let second: CitadelFileSystem
        do {
            second = try await CitadelFileSystem.connect(config: config, connectTimeout: .seconds(15),
                knownHosts: known, onUnknownHostKey: .asking { _ in true })
        } catch { await first.disconnect(); throw error }
        let root = "/config/macscp-commander-\(UUID().uuidString)"
        var failure: (any Error)?
        do {
            try await first.performServerCopyCommand("true")
            await #expect(throws: (any Error).self) { try await first.performServerCopyCommand("exit 7") }
            try await first.createDirectory(at: root)
            try await first.createDirectory(at: root + "/left")
            try await first.createDirectory(at: root + "/right")
            let spy = ServerCopySpy(base: first)
            let reverseSpy = ServerCopySpy(base: second)
            let left = try await tab(fs: spy, path: root + "/left", fixture: fixture)
            let right = try await tab(fs: reverseSpy, path: root + "/right", fixture: fixture)
            let leftID = left.session?.id, rightID = right.session?.id
            let pair = try #require(RemotePanePair.join(left: left, right: right))
            for reverse in [false, true] {
                let owner = reverse ? right : left
                let input = reverse ? second : first
                let sourceDirectory = root + (reverse ? "/right" : "/left")
                let targetDirectory = root + (reverse ? "/left" : "/right")
                let name = reverse ? "return ' copy.bin" : "first ' copy.bin"
                let payload = Data(repeating: 197, count: TransferChunk.size * 3 + 19)
                try await input.write(path: sourceDirectory + "/" + name, mode: .overwrite,
                    contents: AsyncThrowingStream { $0.yield(payload); $0.finish() })
                await #expect(throws: (any Error).self) {
                    try await input.copyFileOnServer(from: sourceDirectory + "/" + name,
                        to: sourceDirectory + "/" + name)
                }
                let item = try await input.stat(path: sourceDirectory + "/" + name)
                #expect(pair.transfer([item], from: owner))
                try await pollUntil("SSH server-side copy finishes") {
                    owner.transferQueue.items.first?.status.isTerminal == true
                }
                #expect(owner.transferQueue.items.first?.status == .finished)
                var result = Data()
                for try await chunk in try await second.readStream(path: targetDirectory + "/" + name) { result.append(chunk) }
                #expect(result == payload)
            }
            #expect(await spy.copies == 1)
            #expect(await reverseSpy.copies == 1)
            #expect(await spy.payloadCalls == 0)
            #expect(await reverseSpy.payloadCalls == 0)
            #expect(left.session?.id == leftID)
            #expect(right.session?.id == rightID)
            let tree = root + "/left/tree"
            try await first.createDirectory(at: tree)
            let treePayload = Data("nested server-side content".utf8)
            try await first.write(path: tree + "/child.txt", mode: .overwrite,
                contents: AsyncThrowingStream { $0.yield(treePayload); $0.finish() })
            #expect(pair.transfer([try await first.stat(path: tree)], from: left))
            try await pollUntil("SSH directory server-side copy finishes") {
                left.transferQueue.items.count == 2 && left.transferQueue.items.allSatisfy { $0.status.isTerminal }
            }
            #expect(left.transferQueue.items.allSatisfy { $0.status == .finished })
            var copiedTree = Data()
            for try await chunk in try await second.readStream(path: root + "/right/tree/child.txt") { copiedTree.append(chunk) }
            #expect(copiedTree == treePayload)
            #expect(await spy.copies == 2)
            #expect(await spy.payloadCalls == 0)
            // Resolve directory aliases on X, not lexically on C.
            try await first.performServerCopyCommand("ln -s " + PosixQuoting.singleQuoted(root + "/left")
                + " " + PosixQuoting.singleQuoted(root + "/alias"))
            await #expect(throws: (any Error).self) {
                try await first.validateServerCopy(sourceDirectory: root + "/left", destinationDirectory: root, name: "alias")
            }
            try await first.validateServerCopy(sourceDirectory: root + "/left", destinationDirectory: root, name: "right")
            await #expect(throws: (any Error).self) {
                try await first.validateServerCopy(sourceDirectory: root + "/left", destinationDirectory: root + "/left", name: "nested")
            }
            // A FIFO keeps cp blocked without sleeps or a large test payload.
            // Observe the actual process before cancelling, then its absence.
            let blocked = root + "/blocked"
            try await first.performServerCopyCommand("mkfifo " + PosixQuoting.singleQuoted(blocked))
            let copying = Task { try await first.copyFileOnServer(from: blocked, to: root + "/blocked-copy") }
            defer { copying.cancel() }
            let probe = "ps -eo comm,args | awk -v needle=" + PosixQuoting.singleQuoted(blocked)
                + " '$1 == \"cp\" && index($0, needle) { found=1 } END { exit !found }'"
            try await pollUntil("remote cp has started") {
                do { try await first.performServerCopyCommand(probe); return true } catch { return false }
            }
            copying.cancel()
            await #expect(throws: CancellationError.self) { try await copying.value }
            try await pollUntil("cancelled remote cp has exited") {
                do { try await first.performServerCopyCommand(probe); return false } catch { return true }
            }
            try await first.performServerCopyCommand("true")
            await left.transferQueue.cancelAll(reason: .userRequested)
            await right.transferQueue.cancelAll(reason: .userRequested)
        } catch { failure = error }
        try? await first.deleteTree(at: root)
        await first.disconnect()
        await second.disconnect()
        if let failure { throw failure }
    }

    private func tab(fs: any RemoteFileSystem, path: String, fixture: RemotePairTestFixture) async throws -> SessionTab {
        let model = ConnectionViewModel(connector: { _, _ in fs })
        model.host = "same-server.invalid"
        model.username = "fixture-user"
        model.authChoice = .agent
        _ = try #require(await model.connect())
        let tab = SessionTab(connectionViewModel: model, certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(), maxConcurrent: 2)
        fixture.attach(tab, path: path, fs: fs)
        return tab
    }
}

private actor ServerCopySpy: ServerSideFileCopying {
    let base: any RemoteFileSystem
    let refusesCopy: Bool
    private(set) var copies = 0
    private(set) var payloadCalls = 0
    init(base: any RemoteFileSystem, refusesCopy: Bool = false) { self.base = base; self.refusesCopy = refusesCopy }
    func copyFileOnServer(from source: String, to destination: String) async throws {
        copies += 1
        if refusesCopy { throw RemoteFSError.protocolError(reason: "Fixture refuses server-side copy") }
        if let remote = base as? any ServerSideFileCopying {
            try await remote.copyFileOnServer(from: source, to: destination)
        } else {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        }
    }
    func validateServerCopy(sourceDirectory: String, destinationDirectory: String, name: String) async throws {
        if let remote = base as? any ServerSideFileCopying {
            try await remote.validateServerCopy(sourceDirectory: sourceDirectory, destinationDirectory: destinationDirectory, name: name)
        }
    }
    func list(path: String) async throws -> [RemoteFileItem] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteFileItem { try await base.stat(path: path) }
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        payloadCalls += 1
        throw RemoteFSError.protocolError(reason: "Unexpected client payload read")
    }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        payloadCalls += 1
        throw RemoteFSError.protocolError(reason: "Unexpected client payload write")
    }
    func delete(path: String) async throws { try await base.delete(path: path) }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func setPermissions(path: String, permissions: UInt32) async throws { try await base.setPermissions(path: path, permissions: permissions) }
    func deleteTree(at path: String) async throws { try await base.deleteTree(at: path) }
    func homeDirectoryPath() async throws -> String { try await base.homeDirectoryPath() }
    func disconnect() async {}
}
