/// Clickable path prefixes. Preserve the original spelling, including repeated
/// separators: object-store keys must not be normalized as filesystem paths.
public struct PathBreadcrumb: Equatable, Sendable, Identifiable {
    public let label: String
    public let path: String
    public var id: String { path }

    public static func components(of path: String) -> [Self] {
        let absolute = path.hasPrefix("/")
        var result: [Self] = absolute ? [Self(label: "/", path: "/")] : []
        var prefix = absolute ? "/" : ""
        let first = absolute ? 1 : 0
        for (index, component) in path.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
            if index < first { continue }
            if index > first { prefix += "/" }
            prefix += component
            if !component.isEmpty {
                result.append(Self(label: String(component), path: prefix))
            }
        }
        return result
    }
}
