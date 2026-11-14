import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@MainActor
struct SessionServerSnapshotRenderingTests {
    @Observable final class Size { var height: CGFloat = 0 }

    @Test(arguments: [false, true])
    func savedInventoryRendersWithoutAConnection(grouped: Bool) async throws {
        _ = NSApplication.shared
        let session = StoredSession(name: "Fixture", ssh: .init(host: "fixture.invalid", username: "fixture", authKind: .agent))
        let inventory = """
            os Synthetic Linux 1.0
            memory 1000 68719476736
            users 1 12
            account-scope regular-local
            local eth0 192.0.2.8
            local eth0 2001:db8:aaaa:bbbb:cccc:dddd:eeee:1234
            local eth0 fe80::8
            local eth1 198.51.100.8
            local eth1 2001:db8:1111:2222:3333:4444:5555:6789
            local eth2 192.0.2.9
            public 203.0.113.8
            public 2001:db8:aaaa:bbbb:cccc:dddd:eeee:1234
            volume\t500000000000\t1000000000000\t/dev/md-fixture1\t/data/array one
            volume\t900000000000\t2000000000000\t/dev/md-fixture2\t/database
            blocks-json-begin
            {"blockdevices":[{"name":"/dev/md-fixture1","type":"raid1","size":1000000000000}]}
            blocks-json-end
            """
        let groupedInventory = "\nstorage-summary-begin\nstorage-group\tmd-fixture1\t1000000000000\t500000000000\nstorage-group\tsda\t2000000000000\t1000000000000\nstorage-group\tvg-fixture\t3000000000000\t500000000000\nstorage-summary-end"
        let information = ServerNetworkAddresses.parse(inventory + (grouped ? groupedInventory : ""))
        let snapshot = SessionServerSnapshot(session: session, information: information,
            collectedAt: Date(timeIntervalSince1970: 12345))
        let size = Size()
        let columns = SnapshotNetworkColumn.columns(for: snapshot)
        #expect(columns.count == 4)
        #expect(columns.first?.addresses.count == 3)
        if grouped { #expect(snapshot.volumes.count == 3) }
        let host = NSHostingView(rootView: SessionServerSnapshotView(snapshot: snapshot)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { size.height = $0 }
            .padding(20).frame(width: 1000, height: 300, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 1000)
        #expect(size.height > 0 && size.height < 260, "The saved summary must remain compact with several interfaces")
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        if ProcessInfo.processInfo.environment["MACSCP_SNAPSHOT_PREVIEW"] == "1" {
            try png.write(to: URL(fileURLWithPath: grouped
                ? "/tmp/macscp-server-snapshot-preview-grouped.png" : "/tmp/macscp-server-snapshot-preview.png"))
        }
    }
}
