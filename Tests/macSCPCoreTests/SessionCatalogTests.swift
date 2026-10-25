import Foundation
import Testing
@testable import macSCPCore

/// `SessionCatalog` lists and filters an in-memory set of stored sessions —
/// no disk, no keychain. Every store here is hand-built.
@Suite("Session catalog")
struct SessionCatalogTests {
    // MARK: - (a) No filter: every session, in sidebar order

    @Test func noFilterReturnsEverySessionInSidebarOrder() {
        // Connections precede groups within each parent, with each category
        // alphabetical rather than ordered by stored position. The ungrouped
        // zebra precedes aa-second, which precedes zz-first.
        let zzFirst = StoredGroup(name: "zz-first", position: 1)
        let aaSecond = StoredGroup(name: "aa-second", position: 2)
        var zebra = sshSession(name: "zebra")
        zebra.position = 0
        var middle = sshSession(name: "middle", groupID: zzFirst.id)
        middle.position = 0
        var apple = sshSession(name: "apple", groupID: aaSecond.id)
        apple.position = 0

        let catalog = SessionCatalog(
            sessions: [apple, middle, zebra], groups: [aaSecond, zzFirst])
        let names = catalog.rows(matching: .init()).map(\.name)

        #expect(names == ["zebra", "apple", "middle"])
    }

    // MARK: - (b) group matches ancestor name

    @Test func groupFilterMatchesTheSessionsGroupOrAnyAncestor() {
        let work = StoredGroup(name: "Work")
        let prod = StoredGroup(name: "Prod", parentID: work.id)
        let inProd = sshSession(name: "deep", groupID: prod.id)
        let elsewhere = sshSession(name: "elsewhere")

        let catalog = SessionCatalog(sessions: [inProd, elsewhere], groups: [work, prod])

        #expect(catalog.rows(matching: .init(group: "Work")).map(\.name) == ["deep"])
        #expect(catalog.rows(matching: .init(group: "Prod")).map(\.name) == ["deep"])
        #expect(catalog.rows(matching: .init(group: "work")).map(\.name) == ["deep"])
        #expect(catalog.rows(matching: .init(group: "Nowhere")).isEmpty)
    }

    // MARK: - (c) kind

    @Test func kindFilterKeepsOnlyThatBackend() {
        let ssh = sshSession(name: "a")
        let s3 = s3Session(name: "b")
        let webdav = webdavSession(name: "c")
        let catalog = SessionCatalog(sessions: [ssh, s3, webdav], groups: [])

        #expect(catalog.rows(matching: .init(kind: .s3)).map(\.name) == ["b"])
    }

    // MARK: - (d) name: case-insensitive substring, not a glob

    @Test func nameFilterIsACaseInsensitiveSubstringNotAGlob() {
        let session = sshSession(name: "Production")
        let catalog = SessionCatalog(sessions: [session], groups: [])

        #expect(catalog.rows(matching: .init(name: "prod")).map(\.name) == ["Production"])
        #expect(catalog.rows(matching: .init(name: "PRODUCTION")).map(\.name) == ["Production"])
        #expect(catalog.rows(matching: .init(name: "pro*")).isEmpty)
    }

    // MARK: - (e) filters AND

    @Test func filtersCombineWithAnd() {
        let match = sshSession(name: "prod-box")
        let wrongKind = s3Session(name: "prod-bucket")
        let wrongName = sshSession(name: "staging-box")

        let catalog = SessionCatalog(
            sessions: [match, wrongKind, wrongName], groups: [])
        let filter = SessionCatalog.Filter(kind: .ssh, name: "prod")

        #expect(catalog.rows(matching: filter).map(\.name) == ["prod-box"])
    }

    // MARK: - (f) target per kind

    @Test func targetIsFormattedPerKind() {
        let ssh = sshSession(name: "a", host: "box.example.com", port: 2222, username: "tim")
        let s3 = s3Session(
            name: "b",
            config: StoredS3Config(
                accessKeyID: "AKIA", region: "eu-central-1",
                endpoint: "https://s3.example.com", bucket: "my-bucket", usePathStyle: false))
        let webdav = webdavSession(
            name: "c",
            config: StoredWebDAVConfig(
                baseURL: "https://cloud.example.com/remote.php/dav",
                username: "tim", useNextcloudPath: false))

        let catalog = SessionCatalog(sessions: [ssh, s3, webdav], groups: [])
        let rows = Dictionary(uniqueKeysWithValues: catalog.rows(matching: .init()).map { ($0.name, $0) })

        #expect(rows["a"]?.target == "tim@box.example.com:2222")
        #expect(rows["b"]?.target == "my-bucket @ https://s3.example.com")
        #expect(rows["c"]?.target == "https://cloud.example.com/remote.php/dav")
    }

    @Test func sshTargetAlwaysShowsThePortEvenTheDefault() {
        let session = sshSession(name: "a", host: "box.example.com", port: 22, username: "tim")
        let catalog = SessionCatalog(sessions: [session], groups: [])

        #expect(catalog.rows(matching: .init()).first?.target == "tim@box.example.com:22")
    }

    /// A blockless `.s3`/`.webdav` session is reachable: `SessionStore`'s
    /// load-time hygiene drops a blockless `.ssh` record but has no such
    /// drop for `.s3`/`.webdav` (`SessionStore.swift` ~96-112) — those two
    /// backends never had inventing accessors, so a missing block there has
    /// always been "the empty bag", not a record needing removal. `target`
    /// answers "" rather than fabricating a placeholder host/bucket/URL.
    @Test func blocklessS3AndWebDAVSessionsHaveAnEmptyTarget() {
        let s3 = StoredSession(name: "a", kind: .s3)
        let webdav = StoredSession(name: "b", kind: .webdav)
        let catalog = SessionCatalog(sessions: [s3, webdav], groups: [])
        let rows = Dictionary(uniqueKeysWithValues: catalog.rows(matching: .init()).map { ($0.name, $0) })

        let s3TargetIsEmpty = rows["a"]?.target == ""
        let webdavTargetIsEmpty = rows["b"]?.target == ""
        #expect(s3TargetIsEmpty)
        #expect(webdavTargetIsEmpty)
    }

    // MARK: - (h) secrecy shape

    /// Structural, not a string search on values: `Row` must carry no
    /// property a secret could hide behind, even when the underlying session
    /// has a `keyPath` and a `loginSetID` set.
    @Test func rowCarriesNothingASecretCouldHideBehind() {
        let session = sshSession(
            name: "a", keyPath: "/Users/tim/.ssh/id_ed25519",
            loginSetID: UUID())
        let catalog = SessionCatalog(sessions: [session], groups: [])
        let row = catalog.rows(matching: .init())[0]

        let fieldNames = Set(Mirror(reflecting: row).children.compactMap(\.label))
        let expectedFieldNames: Set<String> = ["name", "kind", "groupPath", "target"]
        #expect(fieldNames == expectedFieldNames)
    }

    // MARK: - (i) groupPath: ancestors joined top-down, empty at top level

    /// `groupPath` itself had no direct pin before this: the group-filter
    /// test above (b) exercises the same "Work > Prod" nesting but only
    /// reads `\.name`, never `\.groupPath` — so a `groupPath` that joined
    /// ancestors in the wrong order, or with the wrong separator, could
    /// regress unnoticed (final-branch-review finding, 2026-09-02).
    @Test func groupPathJoinsAncestorsTopDownAndIsEmptyAtTopLevel() {
        let work = StoredGroup(name: "Work")
        let prod = StoredGroup(name: "Prod", parentID: work.id)
        let nested = sshSession(name: "nested", groupID: prod.id)
        let topLevel = sshSession(name: "top-level")

        let catalog = SessionCatalog(sessions: [nested, topLevel], groups: [work, prod])
        let rows = Dictionary(uniqueKeysWithValues: catalog.rows(matching: .init()).map { ($0.name, $0) })

        let nestedPathIsWorkThenProd = rows["nested"]?.groupPath == "Work / Prod"
        let topLevelPathIsEmpty = rows["top-level"]?.groupPath == ""
        #expect(nestedPathIsWorkThenProd)
        #expect(topLevelPathIsEmpty)
    }

    // MARK: - (j) a duplicated id does not trap

    /// `Dictionary(uniqueKeysWithValues:)` traps the whole process on a
    /// duplicate key — a store file written or merged by two installations
    /// (or corrupted by hand) can carry a duplicated UUID, and that trap
    /// would take the CLI down rather than fail one command
    /// (final-branch-review finding, 2026-09-02). Deliberately not built
    /// red-first against the OLD `uniqueKeysWithValues:` implementation: the
    /// defect there is a fatal trap, not a graceful test failure, so running
    /// this against it would crash the whole test process instead of
    /// reporting one failing test — the fix landed first, this confirms it.
    @Test func aDuplicatedSessionIDDoesNotTrapAndTheFirstOccurrenceWins() {
        let sharedID = UUID()
        let first = sshSession(id: sharedID, name: "first", host: "first.example.com")
        let second = sshSession(id: sharedID, name: "second", host: "second.example.com")

        let catalog = SessionCatalog(sessions: [first, second], groups: [])
        let rows = catalog.rows(matching: .init())

        let everyRowMatchesTheFirstSession = rows.allSatisfy { $0.target == "tim@first.example.com:22" }
        // One row, not two: the re-review of the fix wave found that the
        // dictionary was deduplicated while the tree walk still visited the
        // id twice, so "first wins" printed the first session twice.
        let exactlyOneRow = rows.count == 1
        #expect(exactlyOneRow)
        #expect(everyRowMatchesTheFirstSession)
    }

    // MARK: - (k) a dangling groupID is treated as top level, not dropped

    /// `SidebarOrdering.children(of:in:)` only ever returns a session under
    /// a `parentID` that is either `nil` or names a real group in `tree
    /// .groups` — a session whose `groupID` names NO group in `groups` never
    /// matches any `parentID` the walk in `rows(matching:)` visits, so
    /// without normalization it would vanish from every result silently,
    /// with no error and no trap (final-branch-review finding, 2026-09-02).
    /// `SessionCatalog.init` now nils such a `groupID`, the same rule
    /// `SessionStore.load()` applies on disk — so the session surfaces at
    /// the top level instead of disappearing.
    @Test func aSessionWithADanglingGroupIDSurfacesAtTopLevelRatherThanBeingDropped() {
        let session = sshSession(name: "orphan", groupID: UUID())
        let catalog = SessionCatalog(sessions: [session], groups: [])

        let rows = catalog.rows(matching: .init())

        let orphanSurfaced = rows.map(\.name) == ["orphan"]
        let orphanIsAtTopLevel = rows.first?.groupPath == ""
        #expect(orphanSurfaced)
        #expect(orphanIsAtTopLevel)
    }
}
