import Foundation
import Testing
import macSCPCore
import MacSCPTestSupport

@testable import MacSCPAppKit

@Suite("L10n")
struct L10nTests {
    /// The App layer's lookup falls back to `Bundle.main`, where the key is
    /// absent, so `NSLocalizedString` hands back the `defaultValue` — every
    /// string in English, with no crash and no failing test. Renaming the
    /// target's bundle would have re-armed exactly that.
    ///
    /// The fallback here is deliberately absurd: if the real catalog is
    /// found, no supported language can return this fallback string.
    @Test func aKnownKeyResolvesInsteadOfFallingBackToTheDefault() {
        let resolved = L10n.string("tabs.newConnection", "ZZ-UNRESOLVED-ZZ")
        #expect(resolved != "ZZ-UNRESOLVED-ZZ")
    }

    /// The graceful-degradation half: an unknown key must return the
    /// supplied default rather than an empty string, so a typo shows up as
    /// readable English in the UI instead of a blank control.
    @Test func anUnknownKeyReturnsTheSuppliedDefault() {
        #expect(L10n.string("app.this.key.does.not.exist", "Readable default") == "Readable default")
    }

    /// The bundle the lookup settled on must not be `Bundle.main` — that is
    /// the silent-failure state itself, and the assertion above would still
    /// pass if some unrelated main-bundle key happened to match.
    @Test func theLookupDidNotSettleForTheMainBundle() {
        #expect(L10n.bundle != Bundle.main)
    }

    private func catalogValue(_ language: AppLanguage) throws -> String {
        let path = try #require(L10n.bundle.path(forResource: language.rawValue, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let value = bundle.localizedString(forKey: "connection.connect", value: "MISSING", table: nil)
        #expect(value != "MISSING" && !value.isEmpty)
        return value
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func explicitChoiceUsesTheProductionLookupEvenAfterEnglishWasLoaded(language: AppLanguage) throws {
        let context = LocalizationContext(language: .en, systemLanguages: ["de"])
        #expect(L10n.string("connection.connect", "MISSING", context: context) == (try catalogValue(.en)))
        context.configure(language: language)
        #expect(L10n.string("connection.connect", "MISSING", context: context) == (try catalogValue(language)))
    }

    @Test func systemChoiceUsesTheOSPreferenceRatherThanThePreviousExplicitChoice() throws {
        let context = LocalizationContext(language: .fr, systemLanguages: ["es-MX", "en"])
        let previous = try catalogValue(.fr), system = try catalogValue(.es)
        #expect(previous != system)
        #expect(L10n.string("connection.connect", "MISSING", context: context) == previous)
        context.configure(language: .system)
        #expect(L10n.string("connection.connect", "MISSING", context: context) == system)
    }

    @Test func everyPickerChoiceHasANameInEverySupportedCatalog() throws {
        #expect(!AppLanguage.allCases.isEmpty)
        for language in AppLanguage.allCases where language != .system {
            let path = try #require(L10n.bundle.path(forResource: language.rawValue, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for choice in AppLanguage.allCases {
                let name = bundle.localizedString(forKey: choice.titleKey, value: "MISSING", table: nil)
                #expect(name != "MISSING", "\(language): missing name for \(choice)")
            }
        }
    }

    @Test func settingsPickerUsesTheEntireLanguageModelRatherThanAManualSubset() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let settings = try SourceCorpus.commentFree(of: root.appendingPathComponent(
            "Sources/MacSCPAppKit/SettingsView.swift"))
        #expect(settings.contains("selection: $store.selectedLanguage"))
        #expect(settings.contains("ForEach(AppLanguage.allCases, id:"))
        #expect(settings.contains("L10n.string(language.titleKey, language.rawValue)"))
        #expect(settings.contains(".tag(language)"))
    }
}
