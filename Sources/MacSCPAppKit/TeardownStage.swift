import Foundation
import macSCPCore
import os

enum TeardownStage: CaseIterable {
    case stopEditWatchers

    /// The call this stage stands for, spelled the way `teardown(_:reason:)`
    /// spells it — this is what a log line has to name for the reader to find
    /// the abandoned step.
    var callSite: String {
        switch self {
        case .stopEditWatchers: "editManager.stopAll()"
        }
    }

    var boundSeconds: Int { 5 }

    /// Runs `operation` under this stage's bound. Returns whether it
    /// finished inside it; `false` means the stage was abandoned and
    /// teardown carried on to the next one.
    @discardableResult
    func runBounded(_ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await runBounded(boundSeconds: boundSeconds, operation)
    }

    /// The bound passed explicitly, so the ungated test can exercise the
    /// abandonment branch without spending five real seconds on it. Every
    /// production call site goes through the overload above.
    @discardableResult
    func runBounded(
        boundSeconds: Int, _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let finished = await BoundedClose.run(
            boundSeconds: boundSeconds, operation: operation)
        if !finished {
            // `os.Logger`, at `.error`, and not a new channel of any kind:
            // this file follows `EditorResolver`, which logs its one
            // "configured thing was unusable, carrying on" line the same way
            // under the same subsystem. The alternative on offer was an
            // `AuditEvent`, and it is the wrong shelf twice over — the audit
            // log exists for what the USER did to a STORED session, and
            // `tab.auditRecorder` is nil for an ad-hoc connect, so the
            // channel would be missing in half the cases this fires. What
            // the user needs to know (the connection is gone, these
            // transfers died with it) is already said by `liveness = .lost`
            // and the queue's own items; what is left over is a fact about
            // OUR cleanup, which is a diagnostic.
            //
            // Cleanup failures are errors, but recording still requires the
            // same explicit opt-in as every other application log.
            //
            // `privacy: .public` on both interpolations: neither is user
            // data (one is a fixed call site from `callSite`, the other an
            // integer), and without it the unified log redacts them to
            // `<private>`, which would leave a line that says a stage was
            // abandoned without saying which.
            if DiagnosticLog.shared.isEnabled(.error) {
                Self.logger.error("""
                teardown stage \(callSite, privacy: .public) did not return \
                within \(boundSeconds, privacy: .public)s and was abandoned; \
                teardown continued with the next stage
                """)
            }
        }
        return finished
    }

    private static let logger = Logger(
        subsystem: "retroTools.MacSCP", category: "Teardown")
}
