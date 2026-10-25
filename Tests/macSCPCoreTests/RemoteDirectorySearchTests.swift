import Foundation
import Testing
@testable import macSCPCore

@Suite("Remote search commands, executed", .timeLimit(.minutes(1)))
struct RemoteDirectorySearchTests {
    private func run(_ command: RemoteDirectorySearchCommand) async throws -> Data {
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command.text])
        #expect(result.status == 0)
        return result.stdout
    }

    @Test func nameSearchIsLiteralIncludingShellAndGlobCharacters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-'" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let query = "*\u{0308}?[';$(touch marker)]"
        let wanted = root.appendingPathComponent("before" + query + "after\nname")
        try Data("ordinary".utf8).write(to: wanted)
        try Data().write(to: root.appendingPathComponent("distractor"))
        let command = try RemoteDirectorySearchCommand(path: root.path, query: query, mode: .name)
        let results = try RemoteDirectorySearchCommand.results(await run(command), mode: .name)
        #expect(results == [wanted.path])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func contentSearchHandlesBinaryFilesAndDoesNotFollowDirectorySymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-search-" + UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let query = "-literal.*'\";$(touch marker)"
        let wanted = root.appendingPathComponent("matching\nfile")
        try (Data([0, 255]) + Data(query.utf8)).write(to: wanted)
        try Data(query.utf8).write(to: outside.appendingPathComponent("not-in-scope"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let command = try RemoteDirectorySearchCommand(path: root.path, query: query, mode: .contents)
        #expect(try RemoteDirectorySearchCommand.results(await run(command), mode: .contents) == [wanted.path])
        let missing = try RemoteDirectorySearchCommand(path: root.path, query: "absent", mode: .contents)
        #expect(try RemoteDirectorySearchCommand.results(await run(missing), mode: .contents).isEmpty)
    }

    @Test func remoteErrorsRemainErrorsInsteadOfEmptyResults() async throws {
        let missing = "/macscp-missing-" + UUID().uuidString
        for mode in RemoteDirectorySearchMode.allCases {
            let output = try await run(RemoteDirectorySearchCommand(path: missing, query: "query", mode: mode))
            #expect(throws: (any Error).self) { try RemoteDirectorySearchCommand.results(output, mode: mode) }
        }
    }

    @Test func malformedAndOversizedResponsesAreRejected() throws {
        #expect(throws: FileToolError.commandFailed(-1)) {
            try RemoteDirectorySearchCommand.results(Data("/some/path\0".utf8), mode: .name)
        }
        #expect(throws: FileToolError.resultsTooLarge) {
            try RemoteDirectorySearchCommand.results(Data(repeating: 65, count: RemoteDirectorySearchCommand.outputLimit + 1), mode: .name)
        }
    }

    @Test func theServerCommandCapsItsOwnOutputBeforeItReachesTheSSHStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-results-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suffix = String(repeating: "a", count: 220)
        for index in 0..<5000 {
            try Data().write(to: root.appendingPathComponent(String(index) + suffix))
        }
        let output = try await run(RemoteDirectorySearchCommand(path: root.path, query: "aaa", mode: .name))
        #expect(output.count == RemoteDirectorySearchCommand.outputLimit + 1)
        #expect(throws: FileToolError.resultsTooLarge) {
            try RemoteDirectorySearchCommand.results(output, mode: .name)
        }
    }

    @Test func invalidInputsNeverBecomeCommands() throws {
        for query in ["", "\0", String(repeating: "a", count: FileWindow.maximumQueryBytes + 1)] {
            #expect(throws: FileToolError.invalidQuery) { try RemoteDirectorySearchCommand(path: "/safe", query: query, mode: .contents) }
        }
        #expect(throws: FileToolError.invalidQuery) { try RemoteDirectorySearchCommand(path: "-relative", query: "a", mode: .name) }
    }
}
