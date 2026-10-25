import Foundation
import Testing
@testable import macSCPCore

@Suite("Directory content size")
struct DirectorySizeCalculatorTests {
    let root = RemoteFileItem(name: "root", path: "/root", kind: .directory)

    @Test func includesNestedAndHiddenFilesButNeverDescendsIntoLinks() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/root": [
                RemoteFileItem(name: ".hidden", path: "/root/.hidden", kind: .file, size: 12),
                RemoteFileItem(name: "nested", path: "/root/nested", kind: .directory),
                RemoteFileItem(name: "link", path: "/root/link", kind: .symlink),
            ],
            "/root/nested": [RemoteFileItem(name: "file", path: "/root/nested/file", kind: .file, size: 30)],
        ])
        #expect(try await DirectorySizeCalculator.totalBytes(of: root, on: fs) == 42)
        #expect(await fs.listCallCounts["/root/link"] == nil)
        #expect(await fs.listCallCounts["/root/nested"] == 1)
    }

    @Test func unreadableSubtreeDoesNotMasqueradeAsACompleteTotal() async {
        let fs = MockRemoteFileSystem(tree: ["/root": [
            RemoteFileItem(name: "missing", path: "/root/missing", kind: .directory),
        ]])
        do {
            _ = try await DirectorySizeCalculator.totalBytes(of: root, on: fs)
            Issue.record("An incomplete tree was reported as a complete size")
        } catch {}
    }

    @Test(arguments: ["..", ".", "../outside", "a/b"])
    func rejectsUnsafeNamesBeforeLeavingTheDirectory(name: String) async {
        let fs = MockRemoteFileSystem(tree: ["/root": [
            RemoteFileItem(name: name, path: "/outside", kind: .directory),
        ]])
        do {
            _ = try await DirectorySizeCalculator.totalBytes(of: root, on: fs)
            Issue.record("An unsafe directory entry was accepted")
        } catch {}
        #expect(await fs.listCallCounts.count == 1)
    }

    @Test func emptyDirectoryHasZeroContentBytes() async throws {
        #expect(try await DirectorySizeCalculator.totalBytes(of: root,
            on: MockRemoteFileSystem(tree: ["/root": []])) == 0)
    }

    @Test func cancellationDuringAnEmptyListingDoesNotReturnASuccessfulTotal() async {
        let fs = MockRemoteFileSystem(tree: ["/root": []])
        await fs.gateListCall(at: "/root", onReached: {})
        let task = Task { try await DirectorySizeCalculator.totalBytes(of: root, on: fs) }
        while await fs.listCallCounts["/root"] == nil { await Task.yield() }
        task.cancel()
        #expect(await fs.listCallCounts["/root"] == 1)
        await fs.releaseListGate(at: "/root")
        do {
            _ = try await task.value
            Issue.record("A cancelled calculation returned a successful total")
        } catch is CancellationError {} catch {
            Issue.record("Cancellation produced an unrelated error")
        }
    }

    @Test func localFilesReceiveSizesMissingFromTheFastListing() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("macscp-size-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        try Data(repeating: 7, count: 37).write(to: directory.appendingPathComponent("file"))
        let item = RemoteFileItem(name: directory.lastPathComponent, path: directory.path, kind: .directory)
        #expect(try await DirectorySizeCalculator.totalBytes(of: item, on: LocalFileSystem()) == 37)
    }
}
