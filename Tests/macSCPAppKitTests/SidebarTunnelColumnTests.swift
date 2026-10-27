import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit

@MainActor
struct SidebarTunnelColumnTests {
    @Observable class Metrics { var badges: [Int: CGRect] = [:] }
    private struct Frames: PreferenceKey {
        static var defaultValue: [Int: CGRect] { [:] }
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, next in next })
        }
    }
    private struct Fixture: View {
        let metrics: Metrics
        let labels: [String?] = [nil, "", "12", "99!"]
        var body: some View {
            VStack(spacing: 4) {
                ForEach(labels.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text("Connection \(index)")
                        Spacer(minLength: 0)
                        Text("SCP").font(.system(size: 10.5, weight: .semibold))
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: Frames.self, value: [index: proxy.frame(in: .named("rows"))])
                            } }
                        SidebarTunnelColumn {
                            if let label = labels[index] {
                                HStack(spacing: 2) {
                                    Text(label).font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                    TunnelIcon(size: 12)
                                }
                            }
                        }
                    }
                    .frame(height: 28)
                }
            }
            .padding(8).frame(width: 300)
            .coordinateSpace(name: "rows")
            .onPreferenceChange(Frames.self) { metrics.badges = $0 }
        }
    }

    @Test func protocolBadgesStayAlignedWithMissingStoppedAndActiveTunnelIndicators() async throws {
        let metrics = Metrics()
        let host = NSHostingView(rootView: Fixture(metrics: metrics))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while metrics.badges.count < 4 && clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(metrics.badges.count == 4)
        let first = try #require(metrics.badges[0])
        for badge in metrics.badges.values {
            #expect(abs(badge.maxX - first.maxX) <= 0.5)
        }
    }
}
