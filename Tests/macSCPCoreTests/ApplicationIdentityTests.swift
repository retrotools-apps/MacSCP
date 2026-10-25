import Foundation
import Security
import Testing
@testable import macSCPCore

@Suite("Application identity and credential namespace")
struct ApplicationIdentityTests {
    @Test func canonicalIdentityAndProtectionPreferencesRemainConsistent() {
        #expect(ApplicationIdentity.name == "MacSCP")
        #expect(ApplicationIdentity.bundleIdentifier == "retroTools.MacSCP")
        #expect(CredentialProtection.service == ApplicationIdentity.bundleIdentifier)
        #expect(ApplicationIdentity.credentialMetadataSuite == "retroTools.MacSCP.credentials")
    }

    @Test(arguments: [false, true])
    func keychainQueryUsesOnlyTheCurrentService(usesDataProtection: Bool) {
        let slot = UUID()
        let store = KeychainItemStore(service: CredentialProtection.service,
                                      usesDataProtection: usesDataProtection)
        let query = store.query(for: slot)
        #expect(query[kSecAttrService as String] as? String == ApplicationIdentity.bundleIdentifier)
        #expect(query[kSecAttrAccount as String] as? String == slot.uuidString)
        #expect((query[kSecUseDataProtectionKeychain as String] as? Bool ?? false) == usesDataProtection)
    }
}
