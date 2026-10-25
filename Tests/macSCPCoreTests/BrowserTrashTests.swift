import Foundation
import Synchronization
import Testing
@testable import macSCPCore

@Suite("Browser Trash removal")
struct BrowserTrashTests {
    @Test @MainActor func browserUsesTrashInsteadOfPermanentDeletion() async {
        let fs = TrashFileSystem()
        let vm = RemoteBrowserViewModel(fs: fs)
        #expect(vm.usesTrash)
        await vm.load()
        let error = await vm.deleteItems(vm.items.sorted { $0.name < $1.name })
        #expect(error == nil)
        #expect(await fs.trashed == ["/file", "/folder"])
        #expect(await fs.permanentDeletes == 0)
        #expect(vm.items.isEmpty)
        #expect(RemoteBrowserViewModel(fs: LocalFileSystem()).usesTrash)
        #expect(!RemoteBrowserViewModel(fs: MockRemoteFileSystem()).usesTrash)
    }

    @Test @MainActor func trashFailureStopsWithoutPermanentFallback() async {
        let fs = TrashFileSystem(failingPath: "/file")
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let error = await vm.deleteItems(vm.items.sorted { $0.name < $1.name })
        #expect(error != nil)
        #expect(await fs.trashed == ["/file"])
        #expect(await fs.permanentDeletes == 0)
        #expect(vm.items.count == 2)
    }

    @Test func trashStripsTrailingSlashesAndPropagatesFailure() async {
        let paths = Mutex<[String]>([])
        do {
            try await LocalFileSystem.moveToTrash(path: "/tmp/macscp-link///") { url in
                paths.withLock { $0.append(url.path) }
                throw CocoaError(.fileWriteNoPermission)
            }
            Issue.record("The failing Trash operation unexpectedly succeeded")
        } catch {}
        #expect(paths.withLock { $0 } == ["/tmp/macscp-link"])
    }

    @Test(arguments: ["/", "relative", ""])
    func trashRejectsRootAndNonAbsolutePaths(path: String) async {
        let calls = Mutex(0)
        do {
            try await LocalFileSystem.moveToTrash(path: path) { _ in calls.withLock { $0 += 1 } }
            Issue.record("An unsafe path reached the Trash operation")
        } catch {}
        #expect(calls.withLock { $0 } == 0)
    }
}

private actor TrashFileSystem: TrashSupportingFileSystem {
    let base = MockRemoteFileSystem(tree: ["/": [
        RemoteFileItem(name: "file", path: "/file", kind: .file),
        RemoteFileItem(name: "folder", path: "/folder", kind: .directory),
    ], "/folder": []])
    let failingPath: String?
    private(set) var trashed: [String] = []
    private(set) var permanentDeletes = 0
    init(failingPath: String? = nil) { self.failingPath = failingPath }
    func moveToTrash(path: String) async throws {
        trashed.append(path)
        if path == failingPath { throw RemoteFSError.permissionDenied(path: path) }
        try await base.deleteTree(at: path)
    }
    func list(path: String) async throws -> [RemoteFileItem] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteFileItem { try await base.stat(path: path) }
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.readStream(path: path, fromOffset: offset)
    }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        try await base.write(path: path, mode: mode, contents: contents)
    }
    func delete(path: String) async throws { permanentDeletes += 1 }
    func deleteTree(at path: String) async throws { permanentDeletes += 1 }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func setPermissions(path: String, permissions: UInt32) async throws {}
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}
