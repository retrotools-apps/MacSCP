import Crypto
import Foundation

/// Successful browser locations, kept locally and excluded from session exports.
@MainActor
public final class BrowserLocationStore {
    private let defaults: UserDefaults
    private let key: String

    public init(host: String, port: String, username: String, sessionID: UUID? = nil,
                defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let identity = [sessionID?.uuidString ?? "", host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        String(Int(port) ?? 22), username]
        let data = Data(identity.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        key = "browser.locations.v1.\(digest)"
    }

    public func path(for side: BrowserPaneSide) -> String? {
        guard let value = defaults.dictionary(forKey: key)?[name(for: side)] as? String,
              value.hasPrefix("/") else { return nil }
        return value
    }

    public func save(_ path: String, for side: BrowserPaneSide) {
        guard path.hasPrefix("/") else { return }
        var locations = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        locations[name(for: side)] = path
        defaults.set(locations, forKey: key)
    }

    private func name(for side: BrowserPaneSide) -> String {
        side == .local ? "local" : "remote"
    }
}
