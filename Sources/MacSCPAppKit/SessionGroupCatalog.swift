import Foundation
import macSCPCore

enum SessionGroupCatalog {
    /// A view identity only; never written to SessionStore as a real group.
    static let allConnectionsID = UUID(uuidString: "AB41B81A-5870-4F9A-B42E-A23EE2DFB371")!
    static var allConnections: StoredGroup {
        StoredGroup(id: allConnectionsID, name: L10n.string("sidebar.allConnections", "All connections"))
    }
    /// Preserve sidebar ordering, including descendants, without following a
    /// malformed parent cycle more than once.
    static func sessions(in groupID: UUID, sessions: [StoredSession], groups: [StoredGroup]) -> [StoredSession] {
        if groupID == allConnectionsID { return sessions }
        guard groups.contains(where: { $0.id == groupID }) else { return [] }
        let tree = SidebarOrdering.Tree(groups: GroupTree.repaired(groups), sessions: sessions)
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = []
        var result: [StoredSession] = []
        func visit(_ parent: UUID) {
            guard visited.insert(parent).inserted else { return }
            for item in SidebarOrdering.children(of: parent, in: tree) {
                switch item {
                case .session(let id): if let session = byID[id] { result.append(session) }
                case .group(let id): visit(id)
                }
            }
        }
        visit(groupID)
        return result
    }
}
