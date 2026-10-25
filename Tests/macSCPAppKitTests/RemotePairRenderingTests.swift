import AppKit
import SwiftUI
import Testing
import macSCPCore
@testable import MacSCPAppKit

@MainActor
@Suite("Paired remote workspace rendering", .serialized, .timeLimit(.minutes(1)))
struct RemotePairRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func bothExistingRemoteTablesRenderWithoutConnecting(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let fixture = try RemotePairTestFixture()
        defer { fixture.removeFiles() }
        try Data("left".utf8).write(to: fixture.leftDirectory.appendingPathComponent("left-file.txt"))
        try Data("right".utf8).write(to: fixture.rightDirectory.appendingPathComponent("right-file.txt"))
        await fixture.left.session?.remote.load()
        await fixture.right.session?.remote.load()
        let pair = try #require(RemotePanePair.join(left: fixture.left, right: fixture.right))
        let settings = SettingsStore(directory: fixture.root.appendingPathComponent("settings"))
        settings.autoRefreshEnabled = false
        let view = RemotePairWorkspace(pair: pair, left: fixture.left, right: fixture.right, settings: settings,
            onOpenFile: { _, _, _ in false }, onDropURLs: { _, _, _ in }, onPromise: { _, _, _ in nil })
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1120, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        // Native table construction happens during the first layout turn.
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let tables = descendants(host).compactMap { $0 as? NSTableView }
        #expect(tables.count == 2)
        #expect(tables.allSatisfy { $0.numberOfRows >= 1 })
        for table in tables {
            #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: true) != nil)
            table.layoutSubtreeIfNeeded()
            table.displayIfNeeded()
        }
        window.displayIfNeeded()
        #expect(pair.liveTabs != nil)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
