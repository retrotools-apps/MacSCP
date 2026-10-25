import Foundation
import Testing
@testable import macSCPCore

@Suite("Tunnel service appearance")
struct TunnelAppearanceTests {
    @Test func tunnelsAndConnectionsExposeTheSameCatalogue() {
        #expect(TunnelAppearance.Icon.allCases == SessionAppearance.Icon.allCases)
    }

    @Test func catalogueLogoIdentifiersRoundtripForBothAppearanceTypes() throws {
        let connection = SessionAppearance(icon: .automatic, tint: .purple, applicationLogo: "mysql")
        let tunnel = TunnelAppearance(icon: .automatic, tint: .teal, applicationLogo: "apachetomcat")
        #expect(try JSONDecoder().decode(SessionAppearance.self, from: JSONEncoder().encode(connection)) == connection)
        #expect(try JSONDecoder().decode(TunnelAppearance.self, from: JSONEncoder().encode(tunnel)) == tunnel)
    }

    @Test(arguments: ["secureWeb", "remoteDesktop", "ssh", "files", "monitoring", "logs", "directory", "messaging"])
    func previousTunnelChoicesKeepTheirStoredIdentifiers(identifier: String) throws {
        let icon = try JSONDecoder().decode(TunnelAppearance.Icon.self, from: Data("\"\(identifier)\"".utf8))
        #expect(icon.rawValue == identifier)
    }
    @Test(arguments: TunnelAppearance.Icon.allCases)
    func everyServiceRoleRoundtripsWithItsColor(icon: TunnelAppearance.Icon) throws {
        let appearance = TunnelAppearance(icon: icon, tint: .purple)
        let profile = TunnelProfile(sessionID: UUID(), name: "Service",
            kind: .dynamic(bind: "127.0.0.1", localPort: 19080), appearance: appearance)
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.appearance == appearance)
    }

    @Test func oldProfilesAndUnknownCatalogueEntriesRemainReadable() throws {
        let profile = TunnelProfile(sessionID: UUID(), name: "Legacy",
            kind: .dynamic(bind: "127.0.0.1", localPort: 19080))
        let data = try JSONEncoder().encode(profile)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["appearance"] == nil)
        #expect(try JSONDecoder().decode(TunnelProfile.self, from: data).appearance == nil)
        let future = Data(#"{"icon":"future-service","tint":"future-color"}"#.utf8)
        #expect(try JSONDecoder().decode(TunnelAppearance.self, from: future) == TunnelAppearance())
    }

    @Test func storedAppearanceSurvivesReloadAndGroupMoves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TunnelStore(directory: directory)
        let group = TunnelGroup(name: "Services")
        try store.upsertGroup(group)
        var profile = TunnelProfile(sessionID: UUID(), name: "Desktop",
            kind: .local(bind: "127.0.0.1", localPort: 19389, host: "desktop.example", remotePort: 3389),
            appearance: .init(icon: .remoteDesktop, tint: .teal, applicationLogo: "mysql"))
        try store.upsert(profile)
        profile.groupID = group.id
        try store.upsert(profile)
        #expect(try TunnelStore(directory: directory).readProfiles().get() == [profile])
    }
}
