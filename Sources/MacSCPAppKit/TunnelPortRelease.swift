import Darwin
import Foundation
import macSCPCore

/// Explicit, confirmed recovery of a conflicting local listener. Never used by
/// automatic startup or teardown, and never sends signals to a remote host.
enum TunnelPortRelease {
    struct Owner: Equatable, Sendable, Identifiable {
        let pid: Int32
        let name: String
        let started: String
        var privilegedInspection = false
        var id: Int32 { pid }
    }

    enum Failure: Error, LocalizedError {
        case unavailable, changed, protectedProcess, commandFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: L10n.string("tunnel.release.unavailable", "The process using this port could not be identified.")
            case .changed: L10n.string("tunnel.release.changed", "The port owner changed. Try again to review the current process.")
            case .protectedProcess: L10n.string("tunnel.release.protected", "This port belongs to MacSCP or a system process. Stop its listener from the owning application.")
            case .commandFailed: L10n.string("tunnel.release.failed", "The port could not be released. The tunnel was not restarted.")
            }
        }
    }

    static func available(profile: TunnelProfile, state: TunnelState) -> Bool {
        guard !TunnelEndpoints.listener(profile).remote else { return false }
        if case .failed(.portInUse) = state { return true }
        return false
    }

    static func conflicts(_ address: String, with endpoint: TunnelEndpoints.Listener) -> Bool {
        guard let separator = address.lastIndex(of: ":"),
              Int(address[address.index(after: separator)...]) == endpoint.port else { return false }
        let host = String(address[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let wildcards: Set<String> = ["", "*", "0.0.0.0", "::"]
        let loopbacks: Set<String> = ["localhost", "127.0.0.1", "::1"]
        return host == endpoint.bind || wildcards.contains(host) || wildcards.contains(endpoint.bind)
            || (endpoint.bind == "localhost" && loopbacks.contains(host))
    }

    static func listenerPIDs(_ output: String, endpoint: TunnelEndpoints.Listener) -> Set<Int32> {
        var pid: Int32?
        var result: Set<Int32> = []
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid, conflicts(String(line.dropFirst()), with: endpoint) { result.insert(pid) }
        }
        return result
    }

    static func owners(of endpoint: TunnelEndpoints.Listener, privileged: Bool = false) async throws -> [Owner] {
        guard !endpoint.remote, (1...65535).contains(endpoint.port) else { throw Failure.unavailable }
        let output: String
        if privileged {
            output = try await administrativeRun("/usr/sbin/lsof -nP -iTCP:\(endpoint.port) -sTCP:LISTEN -Fpn || test $? -eq 1")
        } else {
            let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-iTCP:\(endpoint.port)", "-sTCP:LISTEN", "-Fpn"], timeout: .seconds(10))
            guard result.status == 0 || result.status == 1 else { throw Failure.unavailable }
            output = result.stdoutText
        }
        var owners: [Owner] = []
        for pid in listenerPIDs(output, endpoint: endpoint).sorted() {
            guard pid > 1, pid != getpid() else { throw Failure.protectedProcess }
            let started = try await processField(pid, "lstart")
            let name = try await processField(pid, "comm")
            guard !started.isEmpty, !name.isEmpty else { throw Failure.changed }
            owners.append(Owner(pid: pid, name: URL(fileURLWithPath: name).lastPathComponent, started: started, privilegedInspection: privileged))
        }
        return owners
    }

    private static func processField(_ pid: Int32, _ field: String) async throws -> String {
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", String(pid), "-o", "\(field)="], environment: ["LC_ALL": "C"], timeout: .seconds(5))
        guard result.status == 0 else { throw Failure.changed }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recheck the entire reviewed set before any signal. A replacement process
    /// is never silently added to the user's authorization.
    static func release(_ reviewed: [Owner], endpoint: TunnelEndpoints.Listener) async throws {
        guard !reviewed.isEmpty else { throw Failure.unavailable }
        let privileged = reviewed.contains(where: \.privilegedInspection)
        guard try await owners(of: endpoint, privileged: privileged) == reviewed else { throw Failure.changed }
        for owner in reviewed { try await signal(owner, number: SIGTERM, endpoint: endpoint) }
        for _ in 0..<20 {
            if try await owners(of: endpoint, privileged: privileged).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let remaining = try await owners(of: endpoint, privileged: privileged)
        guard remaining.allSatisfy(reviewed.contains) else { throw Failure.changed }
        for owner in remaining { try await signal(owner, number: SIGKILL, endpoint: endpoint) }
        for _ in 0..<20 {
            if try await owners(of: endpoint, privileged: privileged).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.commandFailed
    }

    private static func signal(_ owner: Owner, number: Int32, endpoint: TunnelEndpoints.Listener) async throws {
        guard try await owners(of: endpoint, privileged: owner.privilegedInspection).contains(owner) else { throw Failure.changed }
        if kill(owner.pid, number) == 0 { return }
        guard errno == EPERM else { throw Failure.commandFailed }
        // Native macOS authorization owns the password prompt. Only integer
        // arguments and a validated ps timestamp enter this fixed shell command.
        guard owner.started.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == ":") }) else {
            throw Failure.changed
        }
        let command = "LC_ALL=C; export LC_ALL; test \"$(/bin/ps -p \(owner.pid) -o lstart= | /usr/bin/sed 's/^ *//;s/ *$//')\" = '\(owner.started)' && /usr/sbin/lsof -nP -a -p \(owner.pid) -iTCP:\(endpoint.port) -sTCP:LISTEN -t | /usr/bin/grep -qx '\(owner.pid)' && /bin/kill -\(number) \(owner.pid)"
        _ = try await administrativeRun(command)
    }

    private static func administrativeRun(_ command: String) async throws -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: .seconds(120))
        guard result.status == 0 else { throw Failure.commandFailed }
        return result.stdoutText.replacingOccurrences(of: "\r", with: "\n")
    }
}
