import Foundation
import Testing
import MacSCPTestSupport

@Suite("SSH askpass AppKit event loop")
struct SSHAskpassMainTests {
    @Test func helperUsesAnAppKitLoopInsteadOfDispatchMain() throws {
        let file = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/SSHAskpassMain.swift")
        let source = try SourceCorpus.code(of: file)
        // MainActor alone is insufficient: dispatchMain can release Darwin's
        // original main thread and service the main queue on another thread.
        #expect(source.contains("func runAskpassIfRequested"))
        #expect(source.contains("NSApplication.shared"))
        #expect(source.contains("app.run()"))
        #expect(!source.contains("dispatchMain()"))
        let setup = try #require(source.range(of: "let app = NSApplication.shared"))
        let request = try #require(source.range(of: "Task { @MainActor in"))
        let loop = try #require(source.range(of: "app.run()"))
        #expect(setup.lowerBound < request.lowerBound)
        #expect(request.lowerBound < loop.lowerBound)
    }
}
