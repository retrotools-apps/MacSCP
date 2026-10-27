import Foundation
import Testing
@testable import macSCPCore

struct SessionSchemaTests {
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func storedSSHSessionWritesOnlyItsCurrentConfigurationAndIdentity() throws {
        let config = StoredSSHConfig(host: "host.invalid", username: "operator")
        let session = StoredSession(name: "Server", ssh: config)
        let encoded = try object(session)
        #expect(Set(encoded.keys) == ["id", "name", "kind", "ssh", "position"])
        let ssh = try #require(encoded["ssh"] as? [String: Any])
        #expect(Set(ssh.keys) == ["host", "port", "username", "authKind"])
        #expect(try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session)) == session)
    }

    @Test func nativeExportWritesOnlyItsCurrentPayload() throws {
        let session = ExportedSession(id: UUID(), name: "Server", kind: .ssh)
        let encoded = try object(session)
        #expect(Set(encoded.keys) == ["id", "name", "kind", "fields"])
    }

    @Test func unrecognizedPropertiesAreIgnoredAndNeverCopiedIntoTheCurrentSchema() throws {
        let config = StoredSSHConfig(host: "host.invalid", username: "operator")
        let session = StoredSession(name: "Server", ssh: config)
        var input = try object(session)
        input["unusedDisplayPreference"] = ["unusedValue": true]
        let decoded = try JSONDecoder().decode(StoredSession.self, from: JSONSerialization.data(withJSONObject: input))
        #expect(decoded == session)
        #expect(Set(try object(decoded).keys) == ["id", "name", "kind", "ssh", "position"])
    }
}
