import Foundation
import macSCPCore

/// Materialize the visible tree before List draws it. Every session and group
/// gets its own stable row identity, independent of how many children its
/// preceding sibling currently exposes.
enum SidebarVisibleRows {
    struct Row: Identifiable, Equatable {
        let item: SidebarItem
        let depth: Int
        var startsSection = false
        var id: UUID { item.id }
    }

    static func build(
        under parentID: UUID?, visibility: SidebarVisibility, collapsed: Set<UUID>, hiddenEntries: Set<UUID> = []
    ) -> [Row] {
        var result: [Row] = []
        var visited: Set<UUID> = []
        func visit(_ parentID: UUID?, depth: Int) {
            let children = visibility.children(of: parentID)
            // Root connections are deliberately above folders; sibling order
            // within each kind and all nested folder order stay unchanged.
            let ordered = parentID == nil
                ? children.filter { if case .session = $0 { true } else { false } }
                    + children.filter { if case .group = $0 { true } else { false } }
                : children
            for item in ordered {
                switch item {
                case .session:
                    if let parentID, hiddenEntries.contains(parentID), !visibility.expandsFolders { continue }
                    result.append(Row(item: item, depth: depth))
                case .group(let id):
                    guard visited.insert(id).inserted else { continue }
                    result.append(Row(item: item, depth: depth, startsSection: depth == 0 && !result.isEmpty))
                    if SidebarFolderDisclosure.isOpen(id, collapsed: collapsed, expandsFolders: visibility.expandsFolders) {
                        visit(id, depth: depth + 1)
                    }
                }
            }
        }
        visit(parentID, depth: 0)
        return result
    }
}
