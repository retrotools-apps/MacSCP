import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

@Suite("Unified session transfer menu")
struct SessionTransferMenuTests {
    private func code(_ file: String) throws -> String {
        try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/" + file))
    }

    @Test func menuOffersOnlyTheTwoUnifiedTransferCommands() throws {
        let menu = try code("MacSCPCommands.swift")
        #expect(menu.contains("tabCommands?.exportAllSessions?()"))
        #expect(menu.contains("tabCommands?.importSessions?()"))
        for old in ["importWinSCP", "exportWinSCP", "importFromCyberduck", "importLogins"] {
            #expect(!menu.contains("tabCommands?.\(old)?()"))
        }
        let export = try code("SessionTransferExportSheet.swift")
        #expect(export.contains("@State private var format: Format = .macscp"))
        #expect(export.contains("SessionExportSheet(viewModel:"))
        #expect(export.contains("WinSCPTransferSheet(action: .exportFile"))
        #expect(export.contains(".tag(Format.macscp)"))
        #expect(export.contains(".tag(Format.winscp)"))
        #expect(!export.lowercased().contains("cyberduck"))
    }

    @Test @MainActor func transferLabelsAreTranslatedInEveryCatalog() throws {
        for locale in ["en", "fr", "de", "pl"] {
            let path = try #require(L10n.bundle.path(forResource: locale, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for suffix in ["export", "import", "import.prompt", "import.invalid", "format", "macscp", "winscp", "import.supported"] {
                let key = "transfer." + suffix
                #expect(bundle.localizedString(forKey: key, value: "MISSING", table: nil) != "MISSING")
            }
        }
    }
}
