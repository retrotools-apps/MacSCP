import Foundation
import Testing
@testable import macSCPCore

@Suite("Retired session comment compatibility")
struct RetiredSessionCommentTests {
    @Test func storedSessionsIgnoreTheRetiredFieldWithoutLosingConnectionOrAppearance() throws {
        let raw = Data("""
            {"id":"\(UUID().uuidString)","name":"Database","comment":"Retired description",
             "kind":"ssh","ssh":{"host":"db.example","port":22,"username":"operator","authKind":"password"},
             "appearance":{"icon":"database","tint":"purple"}}
            """.utf8)
        let session = try JSONDecoder().decode(StoredSession.self, from: raw)
        #expect(session.name == "Database")
        #expect(session.ssh?.host == "db.example")
        #expect(session.appearance == .init(icon: .database, tint: .purple))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        #expect(encoded["comment"] == nil)
    }

    @Test func nativeExportsWithRetiredCommentsRemainReadable() throws {
        let raw = Data("""
            {"id":"\(UUID().uuidString)","name":"Server","kind":"ssh","comment":"Retired description",
             "fields":{"SSHField.host":"host.example"}}
            """.utf8)
        let session = try JSONDecoder().decode(ExportedSession.self, from: raw)
        #expect(session.fields["SSHField.host"] == "host.example")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        #expect(encoded["comment"] == nil)
    }
}
