import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore
@testable import MacSCPAppKit

@MainActor
@Suite("Paired remote lifecycle", .timeLimit(.minutes(1)))
struct RemotePairLifecycleTests {
    @Test func concurrentClosersBothWaitForTheConnectionOwnerToFinish() async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let entered = PairTeardownSignal(), release = PairTeardownSignal()
        defer { release.fire() }
        let tracked = PairDisconnectObserver {
            entered.fire()
            try? await release.wait()
            return false
        }
        fixture.attach(fixture.right, path: fixture.rightDirectory.path, fs: tracked)
        var completed = 0
        let first = Task { @MainActor in
            await TabTeardown.run(fixture.right, reason: .userRequested)
            completed += 1
        }
        try await entered.wait()
        let second = Task { @MainActor in
            await TabTeardown.run(fixture.right, reason: .userRequested)
            completed += 1
        }
        try await pollUntil("second closer reaches teardown barrier") {
            fixture.right.disconnectionWaiters.count == 1 || completed > 0
        }
        #expect(fixture.right.disconnectionWaiters.count == 1)
        #expect(completed == 0)
        #expect(fixture.right.isDisconnecting)
        release.fire()
        await first.value
        await second.value
        #expect(completed == 2)
        #expect(fixture.right.disconnectionWaiters.isEmpty)
        #expect(!fixture.right.isDisconnecting)
        #expect(fixture.right.session == nil)
    }

    @Test func closingAnUnlinkedDestinationSettlesIncomingCopiesBeforeDisconnecting() async throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let tracked = PairDisconnectObserver {
            fixture.left.transferQueue.hasActiveItems(destinationTabID: fixture.right.id)
                || fixture.left.conflictBridge.currentPrompt != nil
        }
        fixture.attach(fixture.right, path: fixture.rightDirectory.path, fs: tracked)
        let window = WindowID()
        TabRegistry.shared.register(fixture.left, in: window)
        TabRegistry.shared.register(fixture.right, in: window)
        defer { TabRegistry.shared.release([fixture.left.id, fixture.right.id], from: window) }
        let file = "existing.txt"
        try Data("source".utf8).write(to: fixture.leftDirectory.appendingPathComponent(file))
        try Data("existing destination".utf8).write(to: fixture.rightDirectory.appendingPathComponent(file))
        let item = try await fixture.left.session!.remoteFS.stat(path: fixture.leftDirectory.appendingPathComponent(file).path)
        let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
        #expect(pair.transfer([item], from: fixture.left))
        try await pollUntil("incoming copy conflict appears") { fixture.left.conflictBridge.currentPrompt != nil }
        #expect(TabCloseWarning.hasIncomingTransfers(for: fixture.right.id, in: [fixture.left, fixture.right]))
        pair.detach()
        await TabTeardown.run(fixture.right, reason: .userRequested)
        #expect(await tracked.incomingAtDisconnect == false)
        #expect(fixture.left.transferQueue.items.first?.status == .cancelled)
        #expect(fixture.left.conflictBridge.currentPrompt == nil)
        #expect(fixture.right.session == nil)
        #expect(fixture.left.session != nil)
        #expect(try Data(contentsOf: fixture.rightDirectory.appendingPathComponent(file)) == Data("existing destination".utf8))
    }

    @Test func movingAnOwnedTabToAnotherWindowUnlinksWithoutDisconnecting() throws {
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        let registry = TabRegistry()
        let sourceWindow = WindowID(), targetWindow = WindowID()
        let source = TabsViewModel(initial: fixture.left)
        source.addTab(fixture.right)
        let placeholder = RemotePairTestFixture.tab()
        let target = TabsViewModel(initial: placeholder)
        registry.register(fixture.left, in: sourceWindow)
        registry.register(fixture.right, in: sourceWindow)
        registry.register(placeholder, in: targetWindow)
        let leftID = fixture.left.session?.id, rightID = fixture.right.session?.id
        #expect(RemotePanePair.join(left: fixture.left, right: fixture.right) != nil)
        _ = TabDetachSequence.moveBetweenWindows(fixture.left.id, from: source, sourceWindow: sourceWindow,
            to: target, targetWindow: targetWindow, in: registry, replacement: { RemotePairTestFixture.tab() })
        #expect(fixture.left.remotePair == nil)
        #expect(fixture.right.remotePair == nil)
        #expect(fixture.left.session?.id == leftID)
        #expect(fixture.right.session?.id == rightID)
        #expect(target.tabs.contains { $0 === fixture.left })
        #expect(!source.tabs.contains { $0 === fixture.left })
    }
}

private actor PairDisconnectObserver: RemoteFileSystem {
    let base = LocalFileSystem()
    let beforeDisconnect: @MainActor @Sendable () async -> Bool
    private(set) var incomingAtDisconnect: Bool?
    init(beforeDisconnect: @escaping @MainActor @Sendable () async -> Bool) { self.beforeDisconnect = beforeDisconnect }
    func list(path: String) async throws -> [RemoteFileItem] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteFileItem { try await base.stat(path: path) }
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.readStream(path: path, fromOffset: offset)
    }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        try await base.write(path: path, mode: mode, contents: contents)
    }
    func delete(path: String) async throws { try await base.delete(path: path) }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func setPermissions(path: String, permissions: UInt32) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }
    func deleteTree(at path: String) async throws { try await base.deleteTree(at: path) }
    func homeDirectoryPath() async throws -> String { try await base.homeDirectoryPath() }
    func disconnect() async { incomingAtDisconnect = await beforeDisconnect() }
}

@MainActor
private final class PairTeardownSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async throws {
        try await awaitResumption { continuation in
            Task { @MainActor in
                if self.fired { continuation.resume() }
                else { self.waiters.append(continuation) }
            }
        }
    }
    func fire() {
        fired = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
