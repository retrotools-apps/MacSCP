import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

struct TunnelPortReleaseTests {
    @Test func matchesOnlyConflictingLocalListeners() {
        let endpoint = TunnelEndpoints.Listener(bind: "127.0.0.1", port: 18683, remote: false)
        let output = "p101\nn127.0.0.1:18683\np102\nn192.0.2.1:18683\np103\nn*:18683\np104\nn127.0.0.1:18684\n"
        #expect(TunnelPortRelease.listenerPIDs(output, endpoint: endpoint) == [101, 103])
        #expect(TunnelPortRelease.conflicts("[::1]:18683", with: .init(bind: "::1", port: 18683, remote: false)))
        #expect(!TunnelPortRelease.conflicts("[::1]:18683", with: endpoint))
    }

    @Test func actionRequiresPortConflictAndLocalForwarding() {
        var profile = TunnelProfile(sessionID: UUID(), name: "Test", kind: .local(bind: "127.0.0.1", localPort: 18683, host: "example.invalid", remotePort: 80))
        #expect(TunnelPortRelease.available(profile: profile, state: .failed(.portInUse(port: 18683))))
        #expect(!TunnelPortRelease.available(profile: profile, state: .failed(.connectionFailed)))
        #expect(!TunnelPortRelease.available(profile: profile, state: .active(connections: 0)))
        profile.kind = .remote(bind: "127.0.0.1", remotePort: 18683, localHost: "example.invalid", localPort: 80)
        #expect(!TunnelPortRelease.available(profile: profile, state: .failed(.portInUse(port: 18683))))
    }

    @Test(arguments: [false, true])
    func releasesOnlyTheReviewedChildListener(ignoresTermination: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let script = "import socket,time,sys,signal; signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[2] == 'ignore' else signal.SIG_DFL); s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); open(sys.argv[1],'w').write(str(s.getsockname()[1])); time.sleep(30)"
        let child = Task {
            try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, file.path, ignoresTermination ? "ignore" : "default"], timeout: .seconds(35))
        }
        defer { child.cancel() }
        var port: Int?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8), let value = Int(text) { port = value; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let endpoint = TunnelEndpoints.Listener(bind: "127.0.0.1", port: try #require(port), remote: false)
        let owners = try await TunnelPortRelease.owners(of: endpoint)
        #expect(owners.count == 1)
        let owner = try #require(owners.first)
        // A stale confirmation must not stop even our own test child.
        let stale = TunnelPortRelease.Owner(pid: owner.pid, name: owner.name, started: "stale")
        await #expect(throws: TunnelPortRelease.Failure.self) {
            try await TunnelPortRelease.release([stale], endpoint: endpoint)
        }
        #expect(try await TunnelPortRelease.owners(of: endpoint) == owners)
        try await TunnelPortRelease.release(owners, endpoint: endpoint)
        #expect(try await TunnelPortRelease.owners(of: endpoint).isEmpty)
        let result = try await child.value
        #expect(result.status != 0)
    }
}
