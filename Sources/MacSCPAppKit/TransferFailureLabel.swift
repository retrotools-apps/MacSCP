import Foundation
import macSCPCore

enum TransferFailureLabel {
    /// Where one kind's sentence comes from.
    enum Sentence: Equatable {
        /// Core's catalogue, in all four languages, read through
        /// `TransferFailureKind.message`.
        case core
        /// The App's own catalogue, under `transfers.failure.<name>`, with
        /// the English source text that seeds `en.lproj` and that
        /// `L10n.string` falls back to when the bundle cannot be found.
        case app(key: String, english: String)
    }

    /// The catalogue key of the frame that marks a technical detail. One
    /// spelling, so "what a detail looks like" is decided in one place per
    /// language rather than three times.
    static let detailFrameKey = "transfers.failure.detail %1$@ %2$@"
    static let detailFrameEnglish = "%1$@ (technical detail: %2$@)"

    /// Which catalogue answers for a kind.
    ///
    /// Exhaustive over `TransferFailureKind.Name`, so a kind added in Core
    /// does not compile here until someone has decided whether it says its
    /// own sentence or reads Core's;
    /// `TransferFailureLabelGuardTests.everyKindIsClassifiedAndTranslated`
    /// then holds the answer to the four catalogues.
    static func sentence(for name: TransferFailureKind.Name) -> Sentence {
        switch name {
        case .connectionFailed:
            return .app(
                key: "transfers.failure.connectionFailed",
                english: "The connection to the server failed.")
        case .protocolError:
            return .app(
                key: "transfers.failure.protocolError",
                english: "The server sent an answer that could not be used.")
        case .unknown:
            return .app(key: "transfers.failure.unknown", english: "The transfer failed.")
        // `.finding` is Core's (2026-09-28): a finding IS a catalogue key in
        // all four languages, which is the whole point of the type — so the
        // App has nothing of its own to say for it.
        case .notFound, .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .bucketLevelRefused,
            .crossBucketRenameRefused, .connectionLost, .interrupted, .noFreeName, .finding:
            return .core
        }
    }

    /// The free text a cause carries, or `nil` for the twelve that carry
    /// none. The three listed here are the three `sentence(for:)` answers
    /// `.app` for, and `everyAppOwnedKindCarriesADetail` holds the two
    /// lists to each other.
    static func technicalDetail(of cause: TransferFailureKind) -> String? {
        switch cause {
        case .connectionFailed(let detail), .protocolError(let detail), .unknown(let detail):
            return detail.isEmpty ? nil : detail
        case .notFound, .permissionDenied, .authenticationFailed, .jumpAuthenticationFailed,
            .bucketListForbidden, .bucketListEmpty, .bucketLevelRefused,
            .crossBucketRenameRefused, .connectionLost, .interrupted, .noFreeName, .finding:
            return nil
        }
    }

    /// One cause, as one line, in the app's language.
    static func label(_ cause: TransferFailureKind) -> String {
        switch sentence(for: cause.name) {
        case .core:
            return cause.message
        case .app(let key, let english):
            let prose = L10n.string(key, english)
            guard let detail = technicalDetail(of: cause) else { return prose }
            return String(
                format: L10n.string(detailFrameKey, detailFrameEnglish), prose, detail)
        }
    }

    /// The same sentence for a surface that still holds the raw error — the
    /// path bar's failed listing and the editor's open-failed banner, both
    /// of which format it into a localized frame of their own and would
    /// otherwise put an English `reason` inside it.
    @MainActor static func text(for error: any Error) -> String {
        label(TransferQueueViewModel.failureKind(for: error))
    }
}
