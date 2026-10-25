import Foundation
import Testing
@testable import macSCPCore

@Suite("Portable server information")
struct ServerSystemInformationTests {
    @Test func storageUsesOneReadableUnitAndShowsAvailableAgainstTotal() {
        #expect(ServerSystemFormatting.value("4026531840 8589934592", field: "memory") == "3.8 / 8.0 GiB")
        #expect(ServerSystemFormatting.value("53687091200 107374182400", field: "disk") == "50.0 / 100.0 GiB")
        #expect(ServerSystemFormatting.value("512 1024", field: "memory") == "0.5 / 1.0 KiB")
        #expect(ServerSystemFormatting.value("2048 1024", field: "disk") == "1.0 / 1.0 KiB")
    }

    @Test func uptimeDoesNotRepeatUsersOrLoadAverage() {
        #expect(ServerSystemFormatting.value("1634580", field: "uptime") == "18d 22h 3m")
        #expect(ServerSystemFormatting.value("30", field: "uptime") == "30s")
    }

    @Test func usersShowActiveAgainstLoginAccountsWithoutInventingMissingTotals() {
        #expect(ServerSystemFormatting.value("1 7", field: "users") == "1 / 7")
        #expect(ServerSystemFormatting.value("0 3", field: "users") == "0 / 3")
        #expect(ServerSystemFormatting.value("1", field: "users") == "1 / —")
    }

    @Test func throughputSamplesExposeActualFractionsAndRates() {
        let sample = DiagnosticThroughputProgress(phase: .upload, bytes: 1_000_000, total: 4_000_000, elapsed: 2)
        #expect(sample.fraction == 0.25)
        #expect(sample.megabitsPerSecond == 4)
        #expect(DiagnosticThroughputProgress(phase: .preparing).megabitsPerSecond == 0)
        #expect(DiagnosticThroughputColumn.rateText(bytesPerSecond: 1_000_000) == "8.0 Mbit/s")
        #expect(DiagnosticThroughputColumn.rateText(bytesPerSecond: 0) == "0.0 Mbit/s")
        #expect(DiagnosticThroughputColumn.rateText(bytesPerSecond: .infinity) == nil)
    }

    @Test func automaticTraceRunsOnlyWhenTheMatchingConnectionFailed() async {
        let runner = ConnectionDiagnostics(descriptor: BackendDescriptor.descriptor(for: .ssh),
            values: FieldValues(), secrets: nil, jump: nil, throughput: .init(), traceOnlyOnConnectionFailure: true)
        for id in [DiagnosticStepID.dial, DiagnosticStepID.jumpDial, DiagnosticStepID.targetDialViaJump] {
            let ok = DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id)).finish(.ok, "")
            let failed = DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id)).finish(.failed("refused"), "")
            #expect(await !runner.shouldTrace(.complete, steps: [ok], dialID: id))
            #expect(await runner.shouldTrace(.complete, steps: [failed], dialID: id))
            #expect(await runner.shouldTrace(.trace, steps: [ok], dialID: id))
            #expect(await !runner.shouldTrace(.ping, steps: [failed], dialID: id))
        }
    }

    @Test func windowsCommandKeepsPathsLiteralAndPublicLookupsOptIn() throws {
        let path = "C:/data/a'b; Write-Output INJECTED"
        let command = ServerNetworkAddresses.windowsCommand(includePublic: false, includeSystem: true, directory: path)
        #expect(command.hasPrefix("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "))
        let data = try #require(Data(base64Encoded: String(command.split(separator: " ").last!)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("Get-CimInstance Win32_OperatingSystem"))
        #expect(script.contains("Get-CimInstance Win32_UserAccount"))
        #expect(script.contains("Get-Item -LiteralPath 'C:/data/a''b; Write-Output INJECTED'"))
        #expect(!script.contains("Invoke-RestMethod"))
        #expect(!script.contains("Invoke-Expression"))
        #expect(script.contains("FreePhysicalMemory * 1024"))
    }

    @Test func nativeMacProbeUsesVersionAndSizedMemoryAndDiskWithoutPrivileges() async throws {
        let command = ServerNetworkAddresses.command(includePublic: false, includeSystem: true, directory: "/tmp")
        let output = try await SubprocessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
        #expect(output.status == 0)
        let result = ServerNetworkAddresses.parse(output.stdoutText)
        #expect(result.system["os"]?.hasPrefix("macOS ") == true)
        #expect(result.system["memory"]?.split(separator: " ").count == 2)
        #expect(result.system["disk"]?.split(separator: " ").count == 2)
        #expect(result.system["uptime"].flatMap(Double.init) != nil)
        #expect(result.system["users"]?.split(separator: " ").count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_SYSTEM_PROBE"] == "1"))
    func existingLinuxFixtureAnswersAsAnUnprivilegedUser() async throws {
        let command = ServerNetworkAddresses.command(includePublic: false, includeSystem: true, directory: "/tmp")
        let output = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/local/bin/docker"),
            arguments: ["exec", "--user", "1000:1000", "macscp-test-sshd", "/bin/sh", "-c", command])
        #expect(output.status == 0)
        let result = ServerNetworkAddresses.parse(output.stdoutText)
        #expect(result.system["os"] != nil)
        #expect(result.system["kernel"]?.hasPrefix("Linux ") == true)
        #expect(result.system["memory"]?.split(separator: " ").count == 2)
        #expect(result.system["disk"]?.split(separator: " ").count == 2)
        #expect(result.system["uptime"].flatMap(Double.init) != nil)
        #expect(result.system["users"]?.split(separator: " ").count == 2)
    }

    @Test func fullTracePolicyAllowsEveryHopToRun() {
        #expect(ConnectionDiagnostics.fullTraceBudget > NetworkTrace.hopTimeout * NetworkTrace.defaultMaxHops)
        #expect(JumpProbeCommand.tracerouteMaxHops(budget: ConnectionDiagnostics.fullTraceBudget) == NetworkTrace.defaultMaxHops)
    }
}
