import Foundation
import MacSCPTestSupport
import Testing

/// Complements LivenessDotPlanTests with source-level checks of the view's
/// delegation and accessibility. This does not simulate VoiceOver or clicks.
@Suite("Liveness dot wiring guard")
struct LivenessDotWiringGuardTests {
    @Test func dotUsesThePlanAndExposesItsMeaningBeyondColor() throws {
        let file = SourceCorpus.packageRoot.appendingPathComponent("Sources/MacSCPAppKit/TabStripView.swift")
        let source = try SourceCorpus.code(of: file)
        let body = try #require(SourceSpan.body(after: "private var livenessDot: some View", in: source))
        #expect(body.contains("LivenessDotPlan.appearance(for: tab.liveness)"))
        #expect(body.contains(".fill(appearance.color)"))
        #expect(body.contains(".help("))
        #expect(body.contains(".accessibilityLabel("))
    }
}
