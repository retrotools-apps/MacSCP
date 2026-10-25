import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Overview action consistency")
struct OverviewActionStyleTests {
    @Test func allThreeActionsShareTheHoverAwareStyle() throws {
        let root = SourceCorpus.packageRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let overview = try SourceCorpus.code(of: root.appendingPathComponent("SessionOverviewView.swift"))
        for action in ["connectControl", "editControl", "diagnoseControl"] {
            let control = try #require(SourceSpan.body(after: "private var \(action): some View", in: overview))
            #expect(control.contains("Button("))
            #expect(control.contains(".buttonStyle(.polished)"))
            #expect(control.contains(".fixedSize(horizontal: true, vertical: false)"))
        }
        let style = try SourceCorpus.code(of: root.appendingPathComponent("PolishedButtonStyle.swift"))
        #expect(style.contains(".onHover { hovered = $0 }"))
        #expect(style.contains("isEnabled && hovered"))
        #expect(style.contains("accessibilityReduceMotion"))
    }
}
