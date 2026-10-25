import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

@Suite("Plural catalogs")
struct PluralCatalogTests {
    private static let languages = ["en", "de", "fr", "pl", "es", "ro", "it"]

    private static func catalogKeys() -> [(key: String, defaultValue: String)] {
        [
            ("logins.export.summary %lld", "%lld logins will be written to the file."),
            (
                "tabs.closeOthers.incomingTransfers %lld",
                "%lld of them are receiving transfers from other tabs; closing cancels those."
            ),
            ("tunnel.state.activeWithFailures %lld", "Active · %lld connections failed"),
            ("tunnel.state.degraded %lld", "Degraded · %lld connections failed in a row"),
        ]
    }

    /// `tabs.closeOthers.activeTransfers %1$lld %2$lld` (Task 3's bulk-close
    /// warning) carries a SECOND, non-pluralized `%2$lld` argument
    /// (`transferring`) alongside the pluralized `%1$lld` (`tabsClosing`),
    /// so it doesn't fit `catalogKeys()`'s single-`count` shape and gets its
    /// own helpers and tests rather than folding into the generic ones.
    /// The `.stringsdict` ties plural selection to argument 1 only
    /// (`NSStringLocalizedFormatKey` = `%1$#@tabs@`, variable name `tabs`
    /// not `count`) — `transferring` never changes the noun's category.
    private static let activeTransfersKey = "tabs.closeOthers.activeTransfers %1$lld %2$lld"
    private static let activeTransfersDefault =
        "Closing %1$lld tabs cancels active transfers in %2$lld of them."

    /// Loads the `.lproj` bundle for one language directly (rather than
    /// letting `NSLocalizedString` negotiate a language from the process's
    /// own preferences), so each language's catalog content can be targeted
    /// on its own regardless of the machine `swift test` runs on.
    private static func bundle(forLanguage language: String) -> Bundle? {
        guard let lprojPath = L10n.bundle.path(forResource: language, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: lprojPath)
    }

    /// Resolves one plural form the same way the app does — `NSLocalizedString`
    /// through the App layer's own `bundle`/`value`/`comment` shape — except
    /// with an explicit per-language `Locale` passed to `String(format:)` so
    /// the CLDR plural category matches `language` instead of the process's
    /// ambient locale.
    private static func resolvedForm(
        key: String, defaultValue: String, language: String, count: Int
    ) -> String? {
        guard let languageBundle = bundle(forLanguage: language) else { return nil }
        let format = NSLocalizedString(key, bundle: languageBundle, value: defaultValue, comment: "")
        return String(format: format, locale: Locale(identifier: language), count)
    }

    /// Same resolution path as `resolvedForm`, for `activeTransfersKey`'s
    /// two arguments. `transferring` is passed through untouched — only
    /// `tabsClosing` (argument 1) selects the plural category.
    private static func resolvedActiveTransfersForm(
        language: String, tabsClosing: Int, transferring: Int
    ) -> String? {
        guard let languageBundle = bundle(forLanguage: language) else { return nil }
        let format = NSLocalizedString(
            Self.activeTransfersKey, bundle: languageBundle, value: Self.activeTransfersDefault, comment: "")
        return String(format: format, locale: Locale(identifier: language), tabsClosing, transferring)
    }

    private static func wordingIgnoringDigits(_ text: String?) -> String? {
        text.map { $0.filter { !$0.isNumber } }
    }

    @Test(arguments: PluralCatalogTests.languages)
    func everyLanguageDistinguishesOneFromTwoForEveryCountKey(language: String) {
        for entry in Self.catalogKeys() {
            let one = Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: language, count: 1)
            let two = Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: language, count: 2)
            #expect(one != nil, "\(language) is missing its .lproj bundle")
            #expect(
                Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
                "\(language) resolved the same wording for 1 and 2 on \(entry.key): \(one ?? "nil")")
        }
    }

    /// Polish has a third category (`many`, roughly 5+) distinct from both
    /// `one` (1) and `few` (2-4) — a two-way `one`/`other` split, which is
    /// works for several other languages, would be wrong here. Romanian
    /// also has a separate `few` category.
    @Test
    func polishSelectsTheThirdCategoryForFive() {
        for entry in Self.catalogKeys() {
            let one = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "pl", count: 1))
            let few = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "pl", count: 2))
            let many = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "pl", count: 5))
            #expect(one != few && few != many && one != many, "\(entry.key): 1=\(one ?? "nil") 2=\(few ?? "nil") 5=\(many ?? "nil")")
        }
    }

    /// French treats a count of 0 like 1 (its `one` category covers both),
    /// unlike English/German where 0 takes the plural form.
    @Test
    func frenchTreatsZeroLikeOne() {
        for entry in Self.catalogKeys() {
            let zero = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "fr", count: 0))
            let one = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "fr", count: 1))
            let two = Self.wordingIgnoringDigits(
                Self.resolvedForm(key: entry.key, defaultValue: entry.defaultValue, language: "fr", count: 2))
            #expect(zero == one, "\(entry.key): 0 should read like 1 in French, got 0=\(zero ?? "nil") 1=\(one ?? "nil")")
            #expect(one != two, "\(entry.key): 1 and 2 should differ in French")
        }
    }

    @Test func romanianSelectsFewAndOtherForRunningTunnels() throws {
        let bundle = try #require(Self.bundle(forLanguage: "ro"))
        let format = bundle.localizedString(forKey: "tunnel.dock.running %lld", value: "MISSING", table: nil)
        let locale = Locale(identifier: "ro")
        #expect(String(format: format, locale: locale, 1) == "1 tunel activ")
        #expect(String(format: format, locale: locale, 2) == "2 tuneluri active")
        #expect(String(format: format, locale: locale, 20) == "20 de tuneluri active")
        #expect(String(format: format, locale: locale, 0) == "0 tuneluri active")
    }

    /// The production call sites use `L10n.string` and plain
    /// `String(format:)` with no explicit bundle or locale override — this
    /// exercises that exact path end to end, proving the `.stringsdict`
    /// entry is reachable through it rather than only through this suite's
    /// per-language bundle helper.
    ///
    /// Which call sites those are is counted by
    /// `everyPluralKeyIsAskedForInTheApp` below, not described here. The
    /// sentence that used to stand in this place named them — and named
    /// them correctly — but nothing checked it: probe D of Task 1
    /// (2026-09-19) deleted the production branch that asks for
    /// `tunnel.state.degraded %lld` and every case in this suite stayed
    /// green, because every one of them resolves the key through
    /// `L10n.string` and the catalog and never through the `switch` that
    /// asks for it. A description of other code, with nothing reading it —
    /// which is what CLAUDE.md's rule about comments that describe other
    /// code is about.
    @Test
    func resolvesThroughTheProductionLookupPath() {
        for entry in Self.catalogKeys() {
            let format = L10n.string(entry.key, entry.defaultValue)
            let one = String(format: format, 1)
            let two = String(format: format, 2)
            #expect(
                Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
                "\(entry.key) did not distinguish 1 from 2 through L10n.string + String(format:): \(one)")
        }
    }

    /// **Every key this suite guards is asked for by the App**, in at least
    /// one `L10n.string` call in `Sources/MacSCPAppKit` — counted here
    /// rather than listed in a comment. A key whose last production call
    /// site is deleted stops being a key worth a catalog entry, and until
    /// this test existed that deletion read exactly like a suite that was
    /// satisfied.
    ///
    /// `commentFree` and not `code`, deliberately: `code(of:)` blanks
    /// string literals as well as comments, which would blank every key
    /// this test is looking for. A comment that quotes a key is blanked,
    /// so a scanner cannot buy a mention for a call.
    @Test func everyPluralKeyIsAskedForInTheApp() throws {
        let appSources = try SourceCorpus.files(
            under: SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        ).filter { $0.pathExtension == "swift" }
        #expect(appSources.count > 1, "the App's sources were not found — re-anchor this guard")
        let code = try SourceCorpus.commentFree(ofAll: appSources)

        let guarded = Self.catalogKeys() + [(Self.activeTransfersKey, Self.activeTransfersDefault)]
        for entry in guarded {
            let needle = "\"\(entry.key)\""
            let callSites = code.reduce(0) { total, file in
                total + (file.contains(needle) ? 1 : 0)
            }
            #expect(
                callSites >= 1,
                "no file under Sources/MacSCPAppKit asks for \(entry.key) any more")
        }
    }

    /// Structural backstop asked for by the task brief: each `.stringsdict`
    /// must declare `NSStringPluralRuleType`, and Polish's `count` rule must
    /// carry `one`/`few`/`many` (not just `one`/`other`).
    @Test(arguments: PluralCatalogTests.languages)
    func stringsdictDeclaresThePluralRuleType(language: String) {
        guard let languageBundle = Self.bundle(forLanguage: language),
            let url = languageBundle.url(forResource: "Localizable", withExtension: "stringsdict"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            Issue.record("\(language) is missing a parseable Localizable.stringsdict")
            return
        }
        for entry in Self.catalogKeys() {
            guard let rule = plist[entry.key] as? [String: Any],
                let countRule = rule["count"] as? [String: Any]
            else {
                Issue.record("\(language) stringsdict is missing a count rule for \(entry.key)")
                continue
            }
            #expect(countRule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType")
            if language == "pl" {
                #expect(countRule["one"] != nil && countRule["few"] != nil && countRule["many"] != nil)
            } else if language == "ro" {
                #expect(countRule["one"] != nil && countRule["few"] != nil && countRule["other"] != nil)
            } else {
                #expect(countRule["one"] != nil && countRule["other"] != nil)
            }
        }
    }

    // MARK: - `tabs.closeOthers.activeTransfers %1$lld %2$lld` (two-argument key)
    //
    // The same five properties the `catalogKeys()` tests check — counted
    // while writing this sentence — adapted for a plural variable driven by
    // argument 1 (`tabsClosing`) while argument 2 (`transferring`) rides
    // along unpluralized — `catalogKeys()`'s single-`count` helpers can't
    // exercise that, so these are separate rather than folded in.

    @Test(arguments: PluralCatalogTests.languages)
    func everyLanguageDistinguishesOneFromTwoForActiveTransfers(language: String) {
        let one = Self.resolvedActiveTransfersForm(language: language, tabsClosing: 1, transferring: 1)
        let two = Self.resolvedActiveTransfersForm(language: language, tabsClosing: 2, transferring: 1)
        #expect(one != nil, "\(language) is missing its .lproj bundle")
        #expect(
            Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
            "\(language) resolved the same wording for 1 and 2 tabs closing: \(one ?? "nil")")
    }

    @Test
    func polishSelectsTheThirdCategoryForFiveTabsClosing() {
        let one = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "pl", tabsClosing: 1, transferring: 1))
        let few = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "pl", tabsClosing: 2, transferring: 1))
        let many = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "pl", tabsClosing: 5, transferring: 1))
        #expect(one != few && few != many && one != many, "1=\(one ?? "nil") 2=\(few ?? "nil") 5=\(many ?? "nil")")
    }

    @Test
    func frenchTreatsZeroTabsClosingLikeOne() {
        let zero = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "fr", tabsClosing: 0, transferring: 0))
        let one = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "fr", tabsClosing: 1, transferring: 0))
        let two = Self.wordingIgnoringDigits(
            Self.resolvedActiveTransfersForm(language: "fr", tabsClosing: 2, transferring: 0))
        #expect(zero == one, "0 should read like 1 in French, got 0=\(zero ?? "nil") 1=\(one ?? "nil")")
        #expect(one != two, "1 and 2 should differ in French")
    }

    @Test
    func activeTransfersResolvesThroughTheProductionLookupPath() {
        let format = L10n.string(Self.activeTransfersKey, Self.activeTransfersDefault)
        let one = String(format: format, 1, 3)
        let two = String(format: format, 2, 3)
        #expect(
            Self.wordingIgnoringDigits(one) != Self.wordingIgnoringDigits(two),
            "did not distinguish 1 from 2 tabs closing through L10n.string + String(format:): \(one)")
    }

    /// Same structural backstop as `stringsdictDeclaresThePluralRuleType`,
    /// but for the `tabs` variable (not `count`) that
    /// `tabs.closeOthers.activeTransfers %1$lld %2$lld` uses.
    @Test(arguments: PluralCatalogTests.languages)
    func stringsdictDeclaresThePluralRuleTypeForActiveTransfers(language: String) {
        guard let languageBundle = Self.bundle(forLanguage: language),
            let url = languageBundle.url(forResource: "Localizable", withExtension: "stringsdict"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let rule = plist[Self.activeTransfersKey] as? [String: Any],
            let tabsRule = rule["tabs"] as? [String: Any]
        else {
            Issue.record("\(language) stringsdict is missing a tabs rule for \(Self.activeTransfersKey)")
            return
        }
        #expect(tabsRule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType")
        if language == "pl" {
            #expect(tabsRule["one"] != nil && tabsRule["few"] != nil && tabsRule["many"] != nil)
        } else {
            #expect(tabsRule["one"] != nil && tabsRule["other"] != nil)
        }
    }
}
