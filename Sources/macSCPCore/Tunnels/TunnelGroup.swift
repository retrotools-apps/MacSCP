import Foundation

/// Tunnel groups are independent of connection/session groups and carry no credentials.
public struct TunnelGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public var colorHue: Double?
    public var color: GroupColor?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, colorHue: Double? = nil, color: GroupColor? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.colorHue = colorHue
        self.color = color
    }

    /// Includes the selected group; a visited set also bounds malformed legacy trees.
    public static func subtree(_ id: UUID, in groups: [TunnelGroup]) -> Set<UUID> {
        guard groups.contains(where: { $0.id == id }) else { return [] }
        var result: Set<UUID> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for child in groups where child.parentID == parent && result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }

    public static func path(_ group: TunnelGroup, in groups: [TunnelGroup]) -> String {
        var names = [group.name], seen: Set<UUID> = [group.id]
        var parent = group.parentID
        while let id = parent, seen.insert(id).inserted,
              let ancestor = groups.first(where: { $0.id == id }) {
            names.insert(ancestor.name, at: 0)
            parent = ancestor.parentID
        }
        return names.joined(separator: " / ")
    }
}

public enum TunnelGroupError: Error, Equatable, Sendable {
    case emptyName
    case duplicateName
    case missingGroup
    case invalidParent
}
