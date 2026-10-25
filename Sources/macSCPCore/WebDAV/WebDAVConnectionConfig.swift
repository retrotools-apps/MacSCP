import Foundation

/// The persisted, SECRET-FREE WebDAV parameters — stored in
/// `StoredSession.webdav`/exports. The password is never here; it lives only
/// in the Keychain (`SecretStore`), like the SSH password and the S3 secret.
public struct StoredWebDAVConfig: Equatable, Codable, Sendable {
    /// Server origin, optionally with a base path
    /// (`https://dav.example.com/dav`). For Nextcloud the origin alone is
    /// enough — see `useNextcloudPath`.
    public var baseURL: String
    public var username: String
    /// Appends `/remote.php/dav/files/<username>/` to `baseURL`. Set by the
    /// Nextcloud preset; the one accommodation the design allows.
    public var useNextcloudPath: Bool

    public init(baseURL: String, username: String, useNextcloudPath: Bool) {
        self.baseURL = baseURL
        self.username = username
        self.useNextcloudPath = useNextcloudPath
    }

    private enum CodingKeys: String, CodingKey { case baseURL, username, useNextcloudPath }

    public func encode(to encoder: Encoder) throws {
        try WebDAVEndpointSecurity.rejectUserinfo(baseURL)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(username, forKey: .username)
        try container.encode(useNextcloudPath, forKey: .useNextcloudPath)
    }
}

/// The RUNTIME WebDAV connect config: the persisted fields PLUS the transient
/// secret. NOT Codable — never persisted.
public struct WebDAVConnectionConfig: Equatable, Sendable {
    public var baseURL: String
    public var username: String
    public var useNextcloudPath: Bool
    /// Warning: plaintext secret — never log, interpolate or persist it.
    public var password: String

    public init(baseURL: String, username: String, useNextcloudPath: Bool, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.useNextcloudPath = useNextcloudPath
        self.password = password
    }

    /// True when credentials would travel in the clear under Basic auth. Read
    /// by the App to require an explicit confirmation (spec §Klartext-HTTP).
    public var isPlaintextTransport: Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .scheme?.lowercased() == "http"
    }
}

/// Reject rather than silently discard or reinterpret embedded credentials.
enum WebDAVEndpointSecurity {
    static func rejectUserinfo(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            throw RemoteFSError.finding(.webDAVURLCredentials)
        }
        // Also refuse malformed authorities, which URLComponents cannot parse.
        let authority = trimmed.range(of: "://").map {
            trimmed[$0.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        }
        guard components.user == nil, components.password == nil,
              authority?.contains("@") != true else {
            throw RemoteFSError.finding(.webDAVURLCredentials)
        }
    }
}
