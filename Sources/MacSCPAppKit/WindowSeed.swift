import Foundation
import macSCPCore

struct WindowSeed: Codable, Hashable, Sendable {
    /// Unique per seed — see the type's doc comment for why equality must
    /// be per-seed rather than per-content.
    let id: UUID
    /// THE MOVE HALF: the live tabs this window takes over from another
    /// one, in the order it should show them. Empty for a restoration.
    var tabIDs: [UUID]
    /// THE RESTORATION HALF: the tabs this window is to rebuild from
    /// scratch, disconnected, in the order it should show them. Empty for
    /// a move.
    var tabs: [TabSeed]
    /// Whether the window floated above the others when it was described
    /// (Task 4's per-window "Keep on Top"). Only a restoration writes it;
    /// a moved tab arrives in a window that has its own answer.
    var keepOnTop: Bool
    /// Whether this description belongs to the window SwiftUI opens by
    /// itself at launch — the seedless one (`ContentView.isPrimaryWindow`).
    ///
    /// A marker is needed because the primary window cannot be opened with
    /// a seed: carrying one is what MAKES a window non-primary, and the
    /// what's-new sheet, the update alert and the frame autosave name all
    /// hang off that. So the primary window's description travels beside
    /// the seed mechanism (`WindowRestorationLaunch`) rather than through
    /// it, and this is how the launch tells which description is its.
    var isPrimary: Bool
}

extension WindowSeed {
    /// A seed for a MOVE: live tab ids, nothing described.
    init(tabIDs: [UUID], id: UUID = UUID()) {
        self.id = id
        self.tabIDs = tabIDs
        self.tabs = []
        self.keepOnTop = false
        self.isPrimary = false
    }

    /// A seed for a RESTORATION: described tabs, no live ids.
    init(tabs: [TabSeed], keepOnTop: Bool, isPrimary: Bool, id: UUID = UUID()) {
        self.id = id
        self.tabIDs = []
        self.tabs = tabs
        self.keepOnTop = keepOnTop
        self.isPrimary = isPrimary
    }

    /// Written by hand so that a seed from BEFORE Task 5 still decodes.
    ///
    /// Two writers persist these: SwiftUI, which keeps the values its
    /// `WindowGroup` was opened with, and `windows.json`, which outlives
    /// upgrades by design. A decode that threw on a missing field would
    /// not be a compatibility wrinkle — it would be a launch that loses
    /// every window it was asked to restore. So the three fields Task 5
    /// added are optional on the wire and default to "a move seed that
    /// floats nowhere and is not the primary window", which is exactly
    /// what a pre-Task-5 seed was.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabIDs = try container.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? []
        tabs = try container.decodeIfPresent([TabSeed].self, forKey: .tabs) ?? []
        keepOnTop = try container.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? false
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    }
}

/// One tab, described rather than referenced (Detachable Tabs plan,
/// Task 5).
///
/// This is what a restored tab is built from, and what it may not contain
/// is as much of the design as what it does: no host, no username, no
/// path, and above all no secret. The stored session's id is enough —
/// the session itself is read back out of `sessions-v2.json` at launch, so
/// a description that outlives an edited or deleted session degrades to a
/// plain empty tab instead of resurrecting stale connection details.
///
/// The struct body holds stored properties and nothing else, for the same
/// reason `WindowSeed`'s does.
struct TabSeed: Codable, Hashable, Sendable {
    /// The stored session this tab was showing, or `nil` for a tab that
    /// was on an ad-hoc connection or on an empty form. An ad-hoc
    /// connection is deliberately NOT described any further: it exists
    /// only in the form the user typed it into, and reconstructing it from
    /// a file is how a host and username nobody chose to save would end up
    /// on disk.
    var sessionID: UUID?
}
