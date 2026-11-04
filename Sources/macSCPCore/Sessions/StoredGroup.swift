import Foundation

/// A session group shown as a collapsible sidebar row, and — since
/// `parentID` — a node in a tree of arbitrary depth.
/// Deleting a group DISSOLVES it: its sessions and its sub-folders move to
/// the group's own parent, they are never deleted with the group.
public struct StoredGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// The group this group sits inside, if any. `nil` = top level.
    ///
    /// No artificial depth limit, which is what buys the cycle check in
    /// `GroupTree`: a group must never become its own ancestor. A parent that
    /// is absent from the same list is not an error either — `GroupTree`
    /// lifts such a group to the top level rather than dropping it.
    public var parentID: UUID?
    /// Rank among the siblings under the same parent, renumbered on write.
    ///
    /// Deliberately a number ON the element rather than the array order of
    /// the file: `SessionListViewModel.save` upserts by NAME and import and
    /// filtering rebuild the list wholesale, so array order is a property of
    /// a code path nobody promised and no test would notice breaking.
    public var position: Int
    /// Earlier hue-only choices remain readable; a full RGB color takes priority.
    public var colorHue: Double?
    /// Optional opaque sRGB identifier. Nil uses the automatic group treatment.
    public var color: GroupColor?
    /// Stable identity for repeated portable imports; local `id` remains
    /// installation-specific and is always re-keyed.
    public var portableID: UUID?
    /// Optional defaults inherited by sessions in this subtree. They are
    /// references only: credentials remain in the login set's Keychain slot,
    /// and the relay keeps owning its own SSH connection data.
    public var loginSetID: UUID?
    public var sshRelaySessionID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, position: Int = 0, colorHue: Double? = nil, color: GroupColor? = nil, portableID: UUID? = nil, loginSetID: UUID? = nil, sshRelaySessionID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.position = position
        self.colorHue = colorHue
        self.color = color
        self.portableID = portableID
        self.loginSetID = loginSetID
        self.sshRelaySessionID = sshRelaySessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentID, position, colorHue, color, portableID
        case loginSetID, sshRelaySessionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        colorHue = try c.decodeIfPresent(Double.self, forKey: .colorHue).flatMap {
            (0..<1).contains($0) ? $0 : nil
        }
        color = try c.decodeIfPresent(GroupColor.self, forKey: .color)
        portableID = try c.decodeIfPresent(UUID.self, forKey: .portableID)
        loginSetID = try c.decodeIfPresent(UUID.self, forKey: .loginSetID)
        sshRelaySessionID = try c.decodeIfPresent(UUID.self, forKey: .sshRelaySessionID)
    }
}
