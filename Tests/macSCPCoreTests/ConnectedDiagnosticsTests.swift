import Foundation
import Testing
@testable import macSCPCore

@Suite("Existing connection diagnostics")
struct ConnectedDiagnosticsTests {
    // These tests assert collection and classification, not scheduler speed.
    // Execute the real access operation directly; DetachedProbe tests cover
    // deadlines and cancellation separately with controlled scheduling.
    @Test func collectionUsesExistingFilesystemAndRespectsSettings() async {
        let filesystem = InformationFilesystem()
        let disabled = await ConnectedDiagnostics.collect(on: filesystem, directory: "/home/test",
            endpoint: nil, settings: .init(systemInformation: false, publicAddresses: false),
            appVersion: "test", observer: .init(), accessProbe: { await $0() })
        #expect(disabled.steps.map(\.id) == ["session.access"])
        #expect(await filesystem.calls == ["health"])

        let enabled = await ConnectedDiagnostics.collect(on: filesystem, directory: "/home/test",
            endpoint: nil, settings: .init(systemInformation: true, publicAddresses: false),
            appVersion: "test", observer: .init(), accessProbe: { await $0() })
        #expect(enabled.steps.map(\.outcome) == [.ok, .ok])
        #expect(enabled.steps.last?.table?.rows.contains(["diagnostics.system.os", "Debian GNU/Linux 13 (trixie)"]) == true)
        let rows = enabled.steps.last?.table?.rows ?? []
        #expect(rows.contains(["diagnostics.system.memory", "3.8 / 8.0 GiB"]))
        #expect(rows.contains(["diagnostics.system.disk", "50.0 / 100.0 GiB"]))
        #expect(rows.contains(["diagnostics.system.users", "7 / 12"]))
        #expect(rows.contains(["diagnostics.system.uptime", "18d 22h 3m"]))
        #expect(enabled.steps.first?.detail.isEmpty == true)
        #expect(!rows.contains { $0.first == "diagnostics.system.architecture" })
        #expect(await filesystem.calls == ["health", "health", "information false true /home/test"])
    }

    @Test func unavailableCommandsDoNotTurnHealthyAccessIntoSSHFailure() async {
        let filesystem = InformationFilesystem(failsCommands: true)
        let report = await ConnectedDiagnostics.collect(on: filesystem, directory: "/",
            endpoint: nil, settings: .init(publicAddresses: true), appVersion: "test", observer: .init(),
            accessProbe: { await $0() })
        #expect(report.steps.first?.outcome == .ok)
        #expect(report.steps.last?.outcome == .unavailable(DiagnosticReason.commandsUnavailable))
        #expect(await filesystem.calls == ["health", "information true true /"])
    }

    @Test func publicLookupCanRunWithoutSystemCollection() async {
        let filesystem = InformationFilesystem()
        let report = await ConnectedDiagnostics.collect(on: filesystem, directory: "/",
            endpoint: nil, settings: .init(systemInformation: false, publicAddresses: true),
            appVersion: "test", observer: .init(), accessProbe: { await $0() })
        #expect(report.steps.last?.table?.rows == [
            ["diagnostics.system.public4", "203.0.113.4"], ["diagnostics.system.public6", "—"],
        ])
        #expect(await filesystem.calls == ["health", "information true false /"])
    }

    @Test func anUnansweredAccessProbeIsReportedWithoutClaimingAHealthyConnection() async {
        let filesystem = InformationFilesystem()
        let report = await ConnectedDiagnostics.collect(on: filesystem, directory: "/",
            endpoint: nil, settings: .init(systemInformation: false), appVersion: "test", observer: .init(),
            accessProbe: { _ in false })
        #expect(report.steps.map(\.outcome) == [.failed(DiagnosticReason.connectionUnresponsive)])
        #expect(await filesystem.calls.isEmpty)
    }

    @Test func cancelledTransferTestDoesNotWriteOrDisconnect() async {
        let filesystem = InMemoryThroughputFileSystem(home: "/home/test")
        let gate = AsyncSignal()
        let task = Task {
            _ = await gate.wait()
            return await ConnectedDiagnostics.throughput(on: filesystem, settings: .init(),
                endpoint: nil, appVersion: "test", observer: .init())
        }
        task.cancel()
        gate.signal()
        let report = await task.value
        #expect(report.steps.isEmpty)
        #expect(await filesystem.log.isEmpty)
    }

    @Test func transferTestCleansItsFileButKeepsTheConnection() async {
        let filesystem = InMemoryThroughputFileSystem(home: "/home/test")
        let progress = ProgressLog()
        let report = await ConnectedDiagnostics.throughput(on: filesystem, settings: .init(payloadMiB: 1),
            endpoint: nil, appVersion: "test", observer: .init(onThroughputProgress: { progress.append($0) }))
        #expect(report.steps.first?.outcome == .ok)
        let calls = await filesystem.log
        #expect(calls.contains { $0.hasPrefix("write ") })
        #expect(calls.contains { $0.hasPrefix("delete ") })
        #expect(!calls.contains("disconnect"))
        #expect(await filesystem.paths.isEmpty)
        let samples = progress.samples
        #expect(samples.first?.phase == .preparing)
        #expect(samples.contains { $0.phase == .upload && $0.bytes == $0.total && $0.total == 1_048_576 })
        #expect(samples.contains { $0.phase == .download && $0.bytes == $0.total && $0.total == 1_048_576 })
        #expect(samples.last?.phase == .cleanup)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DiagnosticThroughputProgress] = []
    var samples: [DiagnosticThroughputProgress] { lock.withLock { stored } }
    func append(_ sample: DiagnosticThroughputProgress) { lock.withLock { stored.append(sample) } }
}

private actor InformationFilesystem: RemoteFileSystem, ServerInformationProvider {
    private(set) var calls: [String] = []
    let failsCommands: Bool
    init(failsCommands: Bool = false) { self.failsCommands = failsCommands }
    func stat(path: String) async throws -> RemoteFileItem {
        calls.append("stat \(path)")
        return RemoteFileItem(name: "test", path: path, kind: .directory)
    }
    func serverInformation(includePublic: Bool, includeSystem: Bool, directory: String) async throws -> ServerNetworkAddresses {
        calls.append("information \(includePublic) \(includeSystem) \(directory)")
        if failsCommands { throw RemoteFSError.permissionDenied(path: directory) }
        return ServerNetworkAddresses.parse("""
        os Debian GNU/Linux 13 (trixie)
        uptime 1634580
        memory 4026531840 8589934592
        disk 53687091200 107374182400
        users 7 12
        public 203.0.113.4
        """)
    }
    func list(path: String) async throws -> [RemoteFileItem] { throw RemoteFSError.permissionDenied(path: path) }
    func readStream(path: String, fromOffset: UInt64) async throws -> AsyncThrowingStream<Data, Error> { throw RemoteFSError.permissionDenied(path: path) }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws { Issue.record("Unexpected write") }
    func delete(path: String) async throws { Issue.record("Unexpected delete") }
    func deleteTree(at path: String) async throws { Issue.record("Unexpected recursive delete") }
    func homeDirectoryPath() async throws -> String { calls.append("health"); return "/home/test" }
    func createDirectory(at path: String) async throws { Issue.record("Unexpected mkdir") }
    func rename(from: String, to: String) async throws { Issue.record("Unexpected rename") }
    func setPermissions(path: String, permissions: UInt32) async throws { Issue.record("Unexpected chmod") }
    func disconnect() async { Issue.record("The tab owns disconnect") }
}
