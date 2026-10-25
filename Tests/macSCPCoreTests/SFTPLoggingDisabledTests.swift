import Logging
import MacSCPTestSupport
import Testing
@testable import macSCPCore

@Suite("Silent SFTP library logging")
struct SFTPLoggingDisabledTests {
    @Test func executableSuppressesRawDependencyLoggingBeforeAnyEntryPoint() throws {
        let root = SourceCorpus.url(of: .sources)
        let main = try SourceCorpus.code(of: root.appendingPathComponent("MacSCPMain/Main.swift"))
        let bootstrap = try #require(main.range(of: "LibraryLogging.bootstrap()"))
        for entry in ["SSHTLSTransport.runProxyMainIfRequested(", "AppMain.main()"] {
            let entryRange = try #require(main.range(of: entry))
            #expect(bootstrap.upperBound < entryRange.lowerBound)
        }
        let logging = try SourceCorpus.code(of: root.appendingPathComponent("macSCPCore/Diagnostics/LibraryLogging.swift"))
        #expect(logging.contains("LoggingSystem.bootstrap"))
        #expect(logging.contains("SwiftLogNoOpLogHandler()"))
        let app = try SourceCorpus.code(of: root.appendingPathComponent("MacSCPAppKit/MacSCPApp.swift"))
        #expect(app.contains("isLoggingEnabled: { DiagnosticLog.shared.isEnabled(.error) }"))
        let window = try #require(app.range(of: "private func windowContent(seed: WindowSeed?)"))
        let windowContent = String(app[window.upperBound...])
        #expect(windowContent.contains(".onChange(of: settingsStore.diagnosticLogLevel)"))
        #expect(windowContent.contains("DiagnosticLog.shared.configure(level: newLevel)"))
    }

    @Test func sftpUsesANoOpHandlerRatherThanTheGlobalLoggingBackend() {
        let logger = BoundedSFTPSession.silentLogger()
        #expect(logger.label == "macSCP.sftp")
        #expect(logger.handler is SwiftLogNoOpLogHandler)
    }
}
