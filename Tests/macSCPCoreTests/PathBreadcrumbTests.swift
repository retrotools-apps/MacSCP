import Testing
@testable import macSCPCore

@Suite("Clickable path prefixes")
struct PathBreadcrumbTests {
    @Test func absolutePathIncludesEveryNavigableAncestor() {
        let parts = PathBreadcrumb.components(of: "/home/karel/work")
        #expect(parts.map(\.label) == ["/", "home", "karel", "work"])
        #expect(parts.map(\.path) == ["/", "/home", "/home/karel", "/home/karel/work"])
    }

    @Test func rootHasOneButton() {
        #expect(PathBreadcrumb.components(of: "/").map(\.path) == ["/"])
    }

    @Test func relativePathsDoNotAcquireAnAbsolutePrefix() {
        #expect(PathBreadcrumb.components(of: "bucket/folder").map(\.path)
            == ["bucket", "bucket/folder"])
    }

    @Test func emptyPathHasNoInventedDestination() {
        #expect(PathBreadcrumb.components(of: "").isEmpty)
    }

    @Test func separatorsAndObjectKeySpellingAreNotNormalized() {
        #expect(PathBreadcrumb.components(of: "/bucket/a//b/").map(\.path)
            == ["/", "/bucket", "/bucket/a", "/bucket/a//b"])
        #expect(PathBreadcrumb.components(of: "//bucket/x").map(\.path)
            == ["/", "//bucket", "//bucket/x"])
    }

    @Test func namesWithSpacesAndUnicodeRemainLiteral() {
        let parts = PathBreadcrumb.components(of: "/home/été 2026/a%2Fb")
        #expect(parts.last?.label == "a%2Fb")
        #expect(parts.last?.path == "/home/été 2026/a%2Fb")
    }
}
