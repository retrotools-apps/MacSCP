import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

@Suite("Primary connection error messages")
@MainActor
struct ConnectFailureMessagesTests {
    @Test(arguments: ConnectFailureCategory.allCases)
    func categoriesAreVisibleWithoutOpeningDetailsAndLocalized(category: ConnectFailureCategory) throws {
        let content = ConnectFailurePlan.content(hasStoredSession: true, remedy: nil, category: category)
        if category == .unknown {
            #expect(content.title.key == "connection.failed.title")
        } else {
            #expect(content.title.key == "connection.failed.\(category.rawValue).title")
            #expect(content.body.key == "connection.failed.\(category.rawValue).body")
            for locale in ["en", "fr", "de", "pl"] {
                let path = try #require(L10n.bundle.path(forResource: locale, ofType: "lproj"))
                let bundle = try #require(Bundle(path: path))
                for message in [content.title, content.body] {
                    #expect(bundle.localizedString(forKey: message.key, value: "MISSING", table: nil) != "MISSING")
                }
            }
        }
        #expect(content.detailsButton.key == "connection.failed.details")
    }
}
