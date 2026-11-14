import Foundation
import Testing
@testable import macSCPCore

struct ServerLoginAccountsTests {
    @Test func excludesRootServiceAndNonLoginAccountsWithoutSubtractingFromTheResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let passwd = directory.appendingPathComponent("passwd")
        let definitions = directory.appendingPathComponent("login.defs")
        try """
        root:x:0:0:fixture:/root:/bin/bash
        service:x:200:200:fixture:/fixture:/bin/bash
        alice:x:1000:1000:fixture:/home/alice:/bin/bash
        bob:x:1001:1001:fixture:/home/bob:/bin/sh
        disabled:x:1002:1002:fixture:/fixture:/usr/sbin/nologin
        nobody:x:65534:65534:fixture:/fixture:/bin/sh
        """.write(to: passwd, atomically: true, encoding: .utf8)
        try "UID_MIN 1000\nUID_MAX 60000\n".write(to: definitions, atomically: true, encoding: .utf8)
        let command = ServerLoginAccounts.command(passwd: passwd.path, loginDefs: definitions.path)
            + "\nprintf '%s\\n' \"$accounts\"\n"
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
        #expect(result.status == 0)
        #expect(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        try "UID_MIN 1001\nUID_MAX 60000\n".write(to: definitions, atomically: true, encoding: .utf8)
        let narrowed = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
        #expect(narrowed.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }
}
