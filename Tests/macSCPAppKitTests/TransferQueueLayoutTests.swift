import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit
import macSCPCore

@MainActor
@Suite(.serialized)
struct TransferQueueLayoutTests {
    @Observable final class Measurement { var height: CGFloat = 0 }

    @Test(arguments: [1, 2, 5])
    func transferRowsKeepHeightBesideHighPriorityBrowserPanes(itemCount: Int) async throws {
        _ = NSApplication.shared
        let queue = TransferQueueViewModel()
        let fs = LocalFileSystem()
        for index in 0..<itemCount {
            queue.enqueue(fileName: "layout-fixture-\(index)", direction: .upload,
                          source: fs, sourcePath: "/nonexistent-macscp-layout-fixture-\(index)",
                          destination: fs, destinationDirectory: "/nonexistent-macscp-layout-fixture",
                          onCompleted: nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let measurement = Measurement()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Rectangle().frame(minHeight: 200).layoutPriority(1)
            TransferQueueBar(viewModel: queue, sessionName: "Fixture", settingsStore: SettingsStore(directory: directory))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measurement.height = $0 }
        })
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if measurement.height > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!queue.items.isEmpty)
        let listHeight = TransferQueueViewport.height(itemCount: queue.items.count, rowHeight: 24)
        #expect(measurement.height >= listHeight + 20, "Transfer rows and header must remain visible")
        #expect(measurement.height <= listHeight + 50, "The panel must not reserve unused rows")
        await queue.cancelAll(reason: .userRequested)
    }
}
