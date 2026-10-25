import Foundation
import Testing
@testable import macSCPCore

@Suite("Occurrence search and returned windows", .timeLimit(.minutes(1)))
struct FileWindowSearchTests {
    private func withFile(_ body: (String, Data, [UInt64]) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("search-window-'" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let positions = [UInt64(FileWindow.size - 2), UInt64(FileWindow.size + 100), UInt64(2 * FileWindow.size + 31)]
        var bytes = Data(repeating: 0, count: FileWindow.size * 3)
        for position in positions {
            let start = Int(position)
            bytes.replaceSubrange(start..<(start + Data("été".utf8).count), with: Data("été".utf8))
        }
        try bytes.write(to: url)
        try await body(url.path, bytes, positions)
    }

    @Test func localSearchNavigatesBothDirectionsAndReturnsOnlyOneWindow() async throws {
        try await withFile { path, bytes, positions in
            let fs = LocalFileSystem(), query = Data("été".utf8)
            let first = try #require(try await fs.searchWindow(path: path, query: query, direction: .forward, relativeTo: nil))
            #expect(first.offset == positions[0])
            #expect(first.size == UInt64(bytes.count))
            #expect(first.data == bytes.subdata(in: Int(first.offset)..<(Int(first.offset) + FileWindow.size)))
            let second = try #require(try await fs.searchWindow(path: path, query: query, direction: .forward, relativeTo: first.offset))
            #expect(second.offset == positions[1])
            let previous = try #require(try await fs.searchWindow(path: path, query: query, direction: .backward, relativeTo: second.offset))
            #expect(previous == first)
            let last = try #require(try await fs.searchWindow(path: path, query: query, direction: .backward, relativeTo: nil))
            #expect(last.offset == positions[2])
            let absent = try await fs.searchWindow(path: path, query: query, direction: .forward, relativeTo: last.offset)
            #expect(absent == nil)
        }
    }

    @Test func theExecutedRemoteHelperMatchesTheLocalAlgorithmWithoutReturningTheFile() async throws {
        try await withFile { path, bytes, positions in
            let query = Data("été".utf8)
            for (direction, anchor, expected) in [(FileSearchDirection.forward, nil, positions[0]),
                (.forward, positions[0], positions[1]), (.backward, nil, positions[2]),
                (.backward, positions[1], positions[0])] {
                let command = try RemoteFileSearchCommand(path: path, query: query, direction: direction, relativeTo: anchor)
                let output = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command.text])
                #expect(output.status == 0)
                #expect(output.stdout.count <= RemoteFileSearchCommand.outputLimit)
                let result = try #require(try RemoteFileSearchCommand.result(output.stdout))
                #expect(result.offset == expected)
                #expect(result.data == bytes.subdata(in: Int(expected)..<min(bytes.count, Int(expected) + FileWindow.size)))
            }
        }
    }

    @Test func overlappingMatchesAndZeroAreReachableInReverse() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overlap-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abababa".utf8).write(to: url)
        let fs = LocalFileSystem(), query = Data("aba".utf8)
        let last = try await fs.searchWindow(path: url.path, query: query, direction: .backward, relativeTo: nil)
        #expect(last?.offset == 4)
        let middle = try await fs.searchWindow(path: url.path, query: query, direction: .backward, relativeTo: 4)
        #expect(middle?.offset == 2)
        let first = try await fs.searchWindow(path: url.path, query: query, direction: .backward, relativeTo: 2)
        #expect(first?.offset == 0)
        let none = try await fs.searchWindow(path: url.path, query: query, direction: .backward, relativeTo: 0)
        #expect(none == nil)
    }

    @Test func aClosedCommandInputStopsTheServerScan() async throws {
        try await withFile { path, _, _ in
            let command = try RemoteFileSearchCommand(path: path, query: Data("absent".utf8),
                direction: .forward, relativeTo: nil, watchesConnection: true)
            let output = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command.text])
            #expect(output.status == 0)
            #expect(throws: FileToolError.commandFailed(1)) { try RemoteFileSearchCommand.result(output.stdout) }
        }
    }
}
