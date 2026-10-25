import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Session recent connections")
struct SessionRecentConnectionsTests {
    @Test func theOverviewShowsOnlyTheFiveNewestAttemptsWithoutTruncatingTheAuditLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recent-five-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = StoredSession(name: "Fixture", ssh: .init(host: "fixture.invalid", username: "fixture", authKind: .agent))
        let store = AuditLogStore(directory: directory.appendingPathComponent("audit", isDirectory: true))
        let events = (0..<8).map { index in
            AuditEvent(timestamp: Date(timeIntervalSince1970: Double(index)), kind: .connectFailed, detail: "fixture failure")
        }
        for event in events { store.append(event, for: session.id) }
        #expect(store.events(for: session.id).count == 8)
        let model = await SessionOverviewView.load(session: session, groupName: nil, loginSetName: nil,
            directory: directory, secrets: NoSecrets())
        #expect(model.history.map(\.id) == events.suffix(5).reversed().map(\.id))
        #expect(store.events(for: session.id).count == 8)
    }

    @Test func aDisabledHistoryExplainsTheRecordingSetting() {
        #expect(SessionOverviewView.historyEmptyLabel(recordingEnabled: false)
            == L10n.string("overview.history.disabled", "missing"))
        #expect(SessionOverviewView.historyEmptyLabel(recordingEnabled: true)
            == L10n.string("overview.history.empty", "missing"))
        #expect(SessionOverviewView.historyEmptyLabel(recordingEnabled: false)
            != SessionOverviewView.historyEmptyLabel(recordingEnabled: true))
    }

    private struct NoSecrets: SecretPresence {
        func hasSecret(for slot: UUID) -> Bool { false }
    }

    @Test func overviewReadsTheSameAuditDirectoryAsTheConnectionRecorder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = StoredSession(name: "Fixture", ssh: .init(host: "fixture.invalid", username: "fixture", authKind: .agent))
        let store = AuditLogStore(directory: directory.appendingPathComponent("audit", isDirectory: true))
        let started = Date(timeIntervalSince1970: 1000)
        let event = AuditEvent(timestamp: started, kind: .connected, detail: "connected")
        store.append(event, for: session.id)
        #expect(store.events(for: session.id) == [event])

        let open = await SessionOverviewView.load(session: session, groupName: nil, loginSetName: nil,
            directory: directory, secrets: NoSecrets())
        let row = try #require(open.history.first)
        #expect(row.id == event.id)
        #expect(row.outcome == .connected(duration: nil))

        store.append(AuditEvent(timestamp: started.addingTimeInterval(25), kind: .disconnected, detail: "disconnected"), for: session.id)
        #expect(store.events(for: session.id).count == 2)
        let closed = await SessionOverviewView.load(session: session, groupName: nil, loginSetName: nil,
            directory: directory, secrets: NoSecrets())
        #expect(closed.history.first?.outcome == .connected(duration: .seconds(25)))
    }
}
