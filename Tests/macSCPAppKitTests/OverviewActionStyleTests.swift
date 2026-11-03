import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Overview action consistency")
struct OverviewActionStyleTests {
    @Test func connectIsProminentAndEveryActionUsesTheHoverAwareStyle() throws {
        let root = SourceCorpus.packageRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let overview = try SourceCorpus.code(of: root.appendingPathComponent("SessionOverviewView.swift"))
        for action in ["terminalControl", "editControl", "diagnoseControl"] {
            let control = try #require(SourceSpan.body(after: "private var \(action): some View", in: overview))
            #expect(control.contains("Button("))
            #expect(control.contains(".buttonStyle(.polished)"))
            #expect(control.contains(".fixedSize(horizontal: true, vertical: false)"))
        }
        let connect = try #require(
            SourceSpan.body(after: "private var connectControl: some View", in: overview))
        #expect(connect.contains(".buttonStyle(.polishedProminent)"))
        #expect(connect.contains(".fixedSize(horizontal: true, vertical: false)"))
        let style = try SourceCorpus.code(of: root.appendingPathComponent("PolishedButtonStyle.swift"))
        #expect(style.contains(".onHover { hovered = $0 }"))
        #expect(style.contains("isEnabled && hovered"))
        #expect(style.contains("accessibilityReduceMotion"))
    }

    @Test func everyActionHasAnIconAndHostActionsAreSeparatedFromManagement() throws {
        let root = SourceCorpus.packageRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let overview = try SourceCorpus.text(
            of: root.appendingPathComponent("SessionOverviewView.swift"))
        let icons = [
            "connectControl": "play.fill",
            "terminalControl": "terminal",
            "editControl": "pencil",
            "diagnoseControl": "stethoscope",
        ]
        for (controlName, icon) in icons {
            let control = try #require(
                SourceSpan.body(after: "private var \(controlName): some View", in: overview))
            #expect(control.contains("systemImage: \"\(icon)\""))
            #expect(control.contains(".help("))
        }
        #expect(overview.contains("HStack(spacing: 24)"))
    }
}
