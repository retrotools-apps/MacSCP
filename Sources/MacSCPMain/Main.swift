import MacSCPAppKit
import macSCPCore

/// The executable target: an entry point and nothing else. All app code
/// lives in `MacSCPAppKit`, where tests can reach it.
@main
struct Main {
    @MainActor
    static func main() {
        LibraryLogging.bootstrap()
        // AppKit's event loop must not run inside an outstanding async main
        // job: that starves MainActor tasks, including connection attempts.
        SSHTLSTransport.runProxyMainIfRequested(CommandLine.arguments)
        AppMain.runAskpassIfRequested(CommandLine.arguments)
        CredentialMaintenance.runIfRequested(CommandLine.arguments)
        AppMain.main()
    }
}
