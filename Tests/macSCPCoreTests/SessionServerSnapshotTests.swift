import Foundation
import Testing
@testable import macSCPCore

struct SessionServerSnapshotTests {
    @Test func groupedSnapshotKeepsCapacitiesWithoutTheRawPartitionInventoryOrLiveUsage() throws {
        let session = StoredSession(name: "Fixture", ssh: .init(host: "fixture.invalid", username: "fixture", authKind: .agent))
        let information = ServerNetworkAddresses.parse("""
        storage-summary-begin
        storage-group\tsda\t1000\t250
        storage-group\tsda\t2000\t500
        storage-group\tmd0\t9000\t1000
        storage-summary-end
        """)
        let snapshot = SessionServerSnapshot(session: session, information: information)
        #expect(snapshot.groupedStorage == true)
        #expect(snapshot.storageDevices.isEmpty)
        #expect(snapshot.volumes.map(\.device) == ["md0", "sda"])
        #expect(snapshot.volumes.map(\.totalBytes) == [9000, 3000])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        let volumes = try #require(encoded?["volumes"] as? [[String: Any]])
        #expect(volumes.allSatisfy { $0["usedBytes"] == nil })
    }

    @Test func persistsOnlyStableTotalsAndRejectsAChangedEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = StoredSession(name: "Fixture", ssh: .init(host: "fixture.invalid", username: "fixture", authKind: .agent))
        let information = ServerNetworkAddresses.parse("""
            os Synthetic Linux
            uptime 120
            load 1 2 3
            memory 1048576 8589934592
            users 2 7
            local eth0 192.0.2.8
            public 203.0.113.8
            volume\t500\t1000\t/dev/fixture0\t/
            volume\t900\t2000\t/dev/fixture1\t/data
            """)
        let date = Date(timeIntervalSince1970: 12345)
        let snapshot = SessionServerSnapshot(session: session, information: information, collectedAt: date)
        let store = SessionServerSnapshotStore(directory: directory)
        store.save(snapshot, for: session)
        let restored = try #require(SessionServerSnapshotStore(directory: directory).load(for: session))
        #expect(restored == snapshot)
        #expect(restored.collectedAt == date)
        #expect(restored.accounts == 7)
        #expect(restored.memoryBytes == 8589934592)
        #expect(restored.volumes.map(\.totalBytes) == [1000, 2000])
        let file = directory.appendingPathComponent("server-snapshots/\(session.id.uuidString).json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["uptime"] == nil)
        #expect(object["load"] == nil)
        let volumes = try #require(object["volumes"] as? [[String: Any]])
        #expect(volumes.allSatisfy { $0["availableBytes"] == nil })
        session.ssh?.host = "changed.invalid"
        #expect(store.load(for: session) == nil)
        let sessions = SessionStore(directory: directory)
        try sessions.upsert(session)
        try sessions.delete(id: session.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
