import Foundation

/// Pure group-name completion for the CLI. It reads stored metadata only:
/// no credentials, Keychain access, connections or diagnostics.
public enum GroupCompleter {
    public static func complete(prefix: String, in catalog: SessionCatalog) -> [String] {
        catalog.groupNames.filter { $0.hasPrefix(prefix) && hasNoWhitespace($0) }
    }

    public static func complete(prefix: String, storeDirectory: URL) -> [String] {
        let store = SessionStore(directory: storeDirectory)
        guard let sessions = try? store.all(), let groups = try? store.allGroups() else {
            return []
        }
        return complete(prefix: prefix, in: SessionCatalog(sessions: sessions, groups: groups))
    }

    private static func hasNoWhitespace(_ value: String) -> Bool {
        !value.contains(where: \.isWhitespace)
    }
}
