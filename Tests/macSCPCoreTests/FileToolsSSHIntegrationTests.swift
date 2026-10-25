import Foundation
import Testing
@testable import macSCPCore

/// An explicitly selected, local-only SSH fixture. Never uses a saved session
/// or production authentication. The port is separate from the shared rig.
@Suite("File tools over SSH", .enabled(if: ProcessInfo.processInfo.environment["MACSCP_FILETOOLS_SSH_PORT"] != nil), .serialized, .timeLimit(.minutes(1)))
struct FileToolsSSHIntegrationTests {
    private func withFixture(_ body: (CitadelFileSystem, String) async throws -> Void) async throws {
        let port = try #require(Int(ProcessInfo.processInfo.environment["MACSCP_FILETOOLS_SSH_PORT"] ?? ""))
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent("filetools-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: knownHosts) }
        let config = try SSHConnectionConfig(host: "127.0.0.1", port: port, username: "testuser", auth: .password("testpass"))
        let fs = try await CitadelFileSystem.connect(config: config, connectTimeout: .seconds(20),
            knownHosts: KnownHostsStore(directory: knownHosts), onUnknownHostKey: .asking { _ in true })
        let root = "/tmp/macscp-filetools-" + UUID().uuidString
        do {
            try await fs.createDirectory(at: root)
            try await body(fs, root)
            try await fs.deleteTree(at: root)
            await fs.disconnect()
        } catch {
            try? await fs.deleteTree(at: root)
            await fs.disconnect()
            throw error
        }
    }

    @Test func sftpReadsOnlyTheRequestedWindowAndKeepsTheSessionUsable() async throws {
        try await withFixture { fs, root in
            let path = root + "/window.bin"
            var bytes = Data(repeating: 65, count: FileWindow.size * 3)
            bytes.replaceSubrange((FileWindow.size + 5)..<(FileWindow.size + 11), with: Data("needle".utf8))
            try await fs.write(path: path, mode: .overwrite, contents: FileTextCodec.stream(bytes))
            let reader = try await fs.openWindowedFile(path: path)
            do {
                let window = try await reader.read(offset: UInt64(FileWindow.size + 5), count: 6)
                #expect(window == Data("needle".utf8))
                #expect(try await reader.read(offset: 400 * 1024 * 1024 * 1024, count: 32).isEmpty)
                await reader.close()
            } catch { await reader.close(); throw error }
            #expect(try await fs.stat(path: path).size == UInt64(bytes.count))
        }
    }

    @Test func searchesExecuteOnTheSameSSHConnectionAndPreserveLiteralArguments() async throws {
        try await withFixture { fs, root in
            try await fs.createDirectory(at: root + "/nested")
            let query = "*[';$(touch never-created)]"
            let path = root + "/nested/" + query + "\n.bin"
            try await fs.write(path: path, mode: .overwrite, contents: FileTextCodec.stream(Data([0, 255]) + Data(query.utf8)))
            #expect(try await fs.searchDirectory(path: root, query: query, mode: .name) == [path])
            #expect(try await fs.searchDirectory(path: root, query: query, mode: .contents) == [path])
            #expect(try await fs.searchDirectory(path: root, query: "no-match", mode: .contents).isEmpty)
            await #expect(throws: FileToolError.commandFailed(2)) {
                try await fs.searchDirectory(path: root + "/missing-folder", query: "query", mode: .contents)
            }
            let entries = try await fs.list(path: root)
            #expect(entries.map(\.name) == ["nested"])
        }
    }

    @Test func aCancelledSearchPreservesTheFileSession() async throws {
        try await withFixture { fs, root in
            let search = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await fs.searchDirectory(path: root, query: "absent", mode: .contents)
            }
            await #expect(throws: CancellationError.self) { try await search.value }
            let remaining = try await fs.list(path: root)
            #expect(remaining.isEmpty)
        }
    }

    @Test func remoteOccurrenceSearchReturnsTheMatchedWindowInBothDirections() async throws {
        try await withFixture { fs, root in
            let path = root + "/binary-'fixture"
            let query = Data("é';$(touch marker)".utf8)
            var bytes = Data(repeating: 0, count: FileWindow.size * 4)
            let first = FileWindow.size - 2, second = FileWindow.size * 3 + 19
            for position in [first, second] {
                bytes.replaceSubrange(position..<(position + query.count), with: query)
            }
            try await fs.write(path: path, mode: .overwrite, contents: FileTextCodec.stream(bytes))
            let found = try #require(try await fs.searchWindow(path: path, query: query, direction: .forward, relativeTo: nil))
            #expect(found.offset == UInt64(first))
            #expect(found.data == bytes.subdata(in: first..<(first + FileWindow.size)))
            let last = try #require(try await fs.searchWindow(path: path, query: query, direction: .forward, relativeTo: found.offset))
            #expect(last.offset == UInt64(second))
            #expect(last.data.count <= FileWindow.size)
            let previous = try await fs.searchWindow(path: path, query: query, direction: .backward, relativeTo: last.offset)
            #expect(previous == found)
            let boundary = try await fs.searchWindow(path: path, query: query, direction: .backward,
                relativeTo: UInt64(2 * FileWindow.size - query.count + 1))
            #expect(boundary == found)
            let missing = try await fs.searchWindow(path: path, query: query, direction: .forward, relativeTo: last.offset)
            #expect(missing == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_FILETOOLS_EXPECT_NO_PYTHON"] == "1"))
    func missingRemotePythonIsReportedWithoutAFallback() async throws {
        try await withFixture { fs, root in
            await #expect(throws: FileToolError.searchUnavailable) {
                try await fs.searchWindow(path: root + "/not-downloaded", query: Data("query".utf8),
                    direction: .forward, relativeTo: nil)
            }
            let entries = try await fs.list(path: root)
            #expect(entries.isEmpty)
        }
    }
}
