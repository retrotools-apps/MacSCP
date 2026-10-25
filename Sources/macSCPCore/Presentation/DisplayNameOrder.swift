import Foundation

/// Finder-style name ordering: localized, case-insensitive and numeric.
/// Equal names retain their input order rather than reshuffling on reload.
public enum DisplayNameOrder {
    public static func sorted<Element>(_ values: [Element], by name: (Element) -> String) -> [Element] {
        values.enumerated().sorted { lhs, rhs in
            let comparison = name(lhs.element).localizedStandardCompare(name(rhs.element))
            return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
        }.map(\.element)
    }
}
