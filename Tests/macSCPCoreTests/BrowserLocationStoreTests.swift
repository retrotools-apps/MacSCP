import Foundation
import Testing
@testable import macSCPCore

@MainActor
struct BrowserLocationStoreTests {
    @Test func locationsPersistIndependentlyAndAreScopedToConnectionIdentity() throws {
        let suite = "macscp-browser-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func store(host: String = "files.invalid", port: String = "22", user: String = "fixture",
                   id: UUID? = nil) -> BrowserLocationStore {
            BrowserLocationStore(host: host, port: port, username: user, sessionID: id, defaults: defaults)
        }
        let original = store()
        original.save("/local/folder with trailing space ", for: .local)
        original.save("/remote/data", for: .remote)
        #expect(store().path(for: .local) == "/local/folder with trailing space ")
        #expect(store().path(for: .remote) == "/remote/data")
        #expect(store(host: "other.invalid").path(for: .remote) == nil)
        #expect(store(port: "2222").path(for: .remote) == nil)
        #expect(store(user: "other-fixture").path(for: .remote) == nil)
        #expect(store(id: UUID()).path(for: .remote) == nil)
        original.save("relative", for: .remote)
        #expect(store().path(for: .remote) == "/remote/data")
        original.save("/home/fixture", for: .local)
        #expect(store().path(for: .remote) == "/remote/data")
    }
}
