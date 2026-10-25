import Foundation

/// Reads session credentials from the application's Keychain store.
public struct KeychainSecretSource: SecretSource {
    public let label = "keychain"
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    public func secret(for sessionID: UUID) throws -> String? {
        try store.password(for: sessionID)
    }
}

/// One of the four places a secret chain can ever hold a link — named as a
/// fixed PLACE, never a value. No case carries a path, an environment
/// variable's name, or anything else an individual source's own `label`
/// could carry (`EnvironmentSecretSource.label`, for one, names the
/// variable itself) — that is the whole reason this exists instead of
/// reusing `label`: a `.secretRequired` refusal's message is built from a
/// list of these, and it must never be able to interpolate anything that
/// could carry a secret's name, let alone its value.
public enum SecretSourceKind: Equatable, Sendable, CaseIterable {
    case passwordCommand
    case environment
    case keychain
    case managedKeyPassphrase
}

/// A secret chain together with the record of which places it holds, kept
/// as one value so the two can never drift apart.
///
/// Fix round 2 replaced a `secretSourceKinds(in sources:)` that derived
/// `kinds` AFTER the fact, by switching on each source's concrete type. That
/// switch was not total (`default: return nil` on a type it didn't
/// recognize) and nothing enforced that it stay in sync with which types a
/// chain builder actually appends — the fix round 2 coordinator's own
/// scoped re-review planted `EnvironmentSecretSource -> .managedKeyPassphrase`
/// in it and reported six test files, 122 tests, staying green, because
/// nothing exercised the mapping against a real chain. Its own doc
/// comment's "there are only ever these four in this module" was also
/// false the moment it was written: `ChainedSecretSource` (below) is a
/// fifth `SecretSource` conformer in this same file, just not a LINK — it
/// wraps a chain rather than appending to one.
///
/// This type removes the problem instead of guarding it: `sources` and
/// `kinds` are built in lockstep, appended together at each step of
/// `secretSources(for:passwordCommand:keychainStore:keyStore:)` (and the
/// App's own `TunnelSecretSources.chain(for:keys:secrets:)`, which produces
/// the same shape from a different subset/order of links) — there is no
/// separate step that could tag one wrong or drop one silently, and no
/// type-based mapping to keep total as conformers are added.
public struct SecretChain: Sendable {
    public let sources: [any SecretSource]
    public let kinds: [SecretSourceKind]

    /// Both defaults are `[]`, which is what `SecretChain()` — the empty
    /// chain an agent-auth or secret-less session gets — is spelled with.
    /// Defaulting `kinds` ALONE is the visible hole: `SecretChain(sources:)`
    /// builds a chain that resolves secrets and reports no places checked,
    /// which is a weaker message and never a wrong one. Judged harmless
    /// rather than closed, and recounted in the pass that wrote this
    /// sentence: 12 call sites pass `sources` without `kinds`, all of them
    /// in tests (`TunnelConnectionTests` 2, `ForwardingWithoutSFTPITests` 3,
    /// `TunnelRigITests` 7), and none of them reads `kinds` or asserts on
    /// the "no secret found" message it feeds
    /// (`checkedSources:` in `TunnelConnection` and
    /// `SessionConnecting.connect`). Both production builders —
    /// `secretSources(for:passwordCommand:keychainStore:keyStore:)` below
    /// and the App's `TunnelSecretSources.chain(for:keys:secrets:)` — pass
    /// both arrays, appended in lockstep.
    public init(sources: [any SecretSource] = [], kinds: [SecretSourceKind] = []) {
        self.sources = sources
        self.kinds = kinds
    }
}

/// Builds the staged secret sources for a stored session, in the ORDER the
/// M20 design fixes as a security decision: an explicit `--password-command`
/// wins over everything; the environment variable is the CI path (the
/// S3-conventional `AWS_SECRET_ACCESS_KEY` for an S3 session, so existing
/// pipelines don't have to relearn a name; `MACSCP_PASSWORD` for SSH, the
/// name the M1 driver already used); the Keychain is the workstation
/// default, last in line — followed, for an SSH private-key session only, by
/// the passphrase slot of the managed key its `keyPath` names
/// (`ManagedKeyPassphraseSecretSource`, read-only; `keyStore` is the app's
/// managed-key store). `SecretResolver` is what actually enforces "empty
/// means did not deliver" and "a throwing source aborts the whole attempt"
/// — this function only has to get the ORDER right; WHICH variable and
/// WHETHER a secret is needed at all are the backend's own answers since
/// M22/T10 (`secretEnvironmentVariable`, `requiresSecret`), so a fourth
/// protocol needs no edit here.
///
/// This used to live in the CLI target as `secretSources(options:kind:)`
/// (`Sources/MacSCPCLI/SessionConnecting.swift`) — a target with NO test
/// target. A future edit swapping two appends, or dropping the agent-auth
/// guard below, would have compiled and passed the entire suite without
/// this file's tests noticing. Moved here, alongside the source types, so
/// the order and the guard are both pinned.
///
/// An SSH agent-auth session needs no secret at all (M20 design): the agent
/// is an authentication METHOD, not a secret source. Consulting
/// `--password-command`/the environment/Keychain anyway would mean an
/// unrelated broken credential helper could fail an agent-auth connect that
/// never needed a secret in the first place — so this returns an EMPTY
/// chain for that case. `SecretResolver` walking an empty chain harmlessly
/// resolves to `nil`, so callers don't need a separate "does this session
/// need a secret" branch of their own.
///
/// Returns a `SecretChain` (fix round 2) rather than a bare
/// `[any SecretSource]`: `kinds` is appended in the same statement as each
/// `sources.append`, below, so the two arrays cannot desynchronize.

/// The CLI's secret chain as the one source `ConnectionDiagnostics` takes:
/// the first source that answers non-empty wins, the same rule
/// `SecretResolver` applies.
///
/// `SecretResolver` itself hands back a `ResolvedSecret` and is done —
/// `ConnectionDiagnostics` wants a single, reusable `SecretSource` it can
/// hold for the run instead, so this re-applies "first non-empty wins" as a
/// `SecretSource` of its own, and remembers which of its sources actually
/// answered so `--verbose` can name it, the same thing
/// `ResolvedSecret.sourceLabel` is for on the connect path.
///
/// `secret(for:)` is called once per authenticating step against the SAME
/// session id — the dial, then S3 and WebDAV's own contribution probe
/// (`ConnectionDiagnostics`, `--scope complete`) — so without memoizing,
/// `--password-command` on those two backends spawns its helper command
/// TWICE for one diagnosis (final-branch review, 2026-09-04). The first
/// non-nil answer is cached in `answered`, keyed by session id, and every
/// later call for that id returns it without walking `sources` again.
/// Nothing is cached for a MISS (every source answered nil or empty): that
/// outcome is not "the answer is nothing", it is "nothing has answered
/// yet", and a later call is free to try the chain again.
public struct ChainedSecretSource: SecretSource {
    private let sources: [any SecretSource]
    private let answered: AnsweredLabel

    public init(_ sources: [any SecretSource]) {
        self.sources = sources
        self.answered = AnsweredLabel()
    }

    /// The links, in order — for
    /// `ManagedKeyPassphraseSecretSource.unreadableStoreHidAKey(in:)`, which
    /// has to see the managed-key link through the chain a diagnosis holds.
    var links: [any SecretSource] { sources }

    /// The answering source's label after a hit, `"none"` before one —
    /// `"none"` reads as a state no source has reached yet, not as the name
    /// of a source nobody wrote.
    public var label: String { answered.value }

    public func secret(for sessionID: UUID) throws -> String? {
        if let memoized = answered.memoizedSecret(for: sessionID) { return memoized }
        for source in sources {
            guard let value = try source.secret(for: sessionID), !value.isEmpty else { continue }
            answered.value = source.label
            answered.memoize(value, for: sessionID)
            return value
        }
        return nil
    }
}

/// The reference-type box behind `ChainedSecretSource.label` and its
/// per-session memoization.
///
/// Needed because `SecretSource.secret(for:)` is non-mutating — a struct's
/// own stored property cannot record which source answered from inside it,
/// so the record lives in this class instead, the same shape
/// `PasswordCommandSecretSource`'s `CollectedOutput` uses for the same
/// reason. Lock-protected rather than left `@unchecked Sendable` on trust
/// alone: unlike `CollectedOutput`'s single write-then-read handoff on a
/// semaphore, `ChainedSecretSource` is a public `Sendable` value a caller
/// could read `label` from on one thread while `secret(for:)` runs on
/// another.
private final class AnsweredLabel: @unchecked Sendable {
    private let lock = NSLock()
    private var current = "none"
    /// The first non-nil, non-empty secret this chain resolved, per session
    /// id. Keyed rather than a single slot so a chain that were ever (mis)
    /// used for more than one session id could not hand one id's answer
    /// back for another's.
    private var answers: [UUID: String] = [:]

    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func memoizedSecret(for sessionID: UUID) -> String? {
        lock.withLock { answers[sessionID] }
    }

    func memoize(_ secret: String, for sessionID: UUID) {
        lock.withLock { answers[sessionID] = secret }
    }
}
