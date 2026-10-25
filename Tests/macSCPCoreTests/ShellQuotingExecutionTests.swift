import Foundation
import Testing
@testable import macSCPCore

@Suite("SSH shell quoting, executed")
struct ShellQuotingExecutionTests {
    private static let markedQuote = "'\u{0308}"

    private func withScratchDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-quoting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    private func runInBash(_ command: String, in directory: URL) async throws {
        try await run(command, with: "/bin/bash", in: directory)
    }

    private func run(_ command: String, with shell: String, in directory: URL) async throws {
        _ = try await SubprocessRunner.run(
            URL(fileURLWithPath: shell), arguments: ["-c", command], currentDirectory: directory)
    }

    private func markerExists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path)
    }

    @Test func anSSHCommandLineCannotBeBrokenByAMarkedQuoteInTheKeyPath() async throws {
        let marker = "marker-ssh"
        let hostile = "/keys/\(Self.markedQuote); touch \(marker); \(Self.markedQuote)"
        let config = try SSHConnectionConfig(
            host: "example.com", username: "tim",
            auth: .privateKey(keyPath: hostile, passphrase: nil))
        let command = SSHCommandBuilder.shellCommand(for: config)

        try await withScratchDirectory { directory in
            let binDirectory = directory.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true)
            let stub = binDirectory.appendingPathComponent("ssh")
            try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path)

            try await runInBash("PATH='\(binDirectory.path)':\"$PATH\"; \(command)", in: directory)
            #expect(
                !markerExists(marker, in: directory),
                "an ssh argument escaped its single quotes and ran as a command")
        }
    }

    @Test(
        "a metacharacter carrying a combining mark does not pass the host ban list",
        arguments: ["ex\u{0027}\u{0308}ample.com", "ex\u{0024}\u{0308}ample.com",
                    "ex\u{003B}\u{0308}ample.com", "ex\u{0060}\u{0308}ample.com"])
    func aDecoratedMetacharacterIsBannedInAHost(host: String) {
        #expect(throws: (any Error).self) {
            try SSHConnectionConfig(host: host, username: "tim", auth: .password("x"))
        }
    }
}
