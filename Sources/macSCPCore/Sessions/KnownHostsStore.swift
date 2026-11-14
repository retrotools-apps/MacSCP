import Foundation

/// A remembered host key (TOFU). The fingerprint is derived from the blob.
public struct KnownHostKey: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKeyBase64: String

    /// When this key was last trusted (TOFU accept or re-accept). Optional
    /// for decode compatibility: entries written before M10a read as nil
    /// (the UI shows an em dash).
    public let addedAt: Date?

    /// Host is stored lowercased — comparisons are case-insensitive.
    public init(
        host: String, port: Int, keyType: String, publicKeyBase64: String,
        addedAt: Date? = Date()
    ) {
        self.host = host.lowercased()
        self.port = port
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
        self.addedAt = addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Via the normalizing init — otherwise decode would be a second,
        // un-normalized write path (review finding M3d Task 0).
        self.init(
            host: try container.decode(String.self, forKey: .host),
            port: try container.decode(Int.self, forKey: .port),
            keyType: try container.decode(String.self, forKey: .keyType),
            publicKeyBase64: try container.decode(String.self, forKey: .publicKeyBase64),
            addedAt: try container.decodeIfPresent(Date.self, forKey: .addedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, keyType, publicKeyBase64, addedAt
    }

    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(ofKeyBlobBase64: publicKeyBase64) ?? "SHA256:?"
    }
}

/// JSON persistence of known host keys (same pattern as SessionStore:
/// stateless, atomic writes, single-app assumption).
public struct KnownHostsStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("known_hosts.json")
    }

    public func find(host: String, port: Int) throws -> KnownHostKey? {
        try all().first { $0.host == host.lowercased() && $0.port == port }
    }

    public func upsert(_ key: KnownHostKey) throws {
        var keys = try all()
        keys.removeAll { $0.host == key.host && $0.port == key.port }
        keys.append(key)
        try persist(keys)
    }

    /// All remembered keys, host-then-port sorted — the management sheet's
    /// data source (M10a).
    public func allKeys() throws -> [KnownHostKey] {
        try all().sorted {
            $0.host == $1.host ? $0.port < $1.port : $0.host < $1.host
        }
    }

    /// Forgets a host key (M10a): the host becomes unknown again — the next
    /// connect runs the normal TOFU prompt. This is the only mutation the
    /// management UI offers; fingerprints are never editable.
    public func remove(host: String, port: Int) throws {
        var keys = try all()
        keys.removeAll { $0.host == host.lowercased() && $0.port == port }
        try persist(keys)
    }

    /// Replace one unchanged pin with the exact key captured in the failed
    /// handshake, only after the user's explicit replacement action.
    public func replaceChangedKey(_ change: HostKeyMismatchDetails) throws -> Bool {
        guard let candidate = change.candidate, candidate.host.lowercased() == change.host.lowercased(),
              candidate.fingerprintSHA256 == change.presented else { return false }
        var keys = try all()
        guard let index = keys.firstIndex(where: { $0.host == candidate.host.lowercased() && $0.port == candidate.port }),
              keys[index].fingerprintSHA256 == change.expected else { return false }
        keys[index] = KnownHostKey(host: candidate.host, port: candidate.port,
            keyType: candidate.keyType, publicKeyBase64: candidate.publicKeyBase64)
        try persist(keys)
        return true
    }

    private func all() throws -> [KnownHostKey] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([KnownHostKey].self, from: data)
    }

    private func persist(_ keys: [KnownHostKey]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
