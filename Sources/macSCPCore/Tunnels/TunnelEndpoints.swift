import Foundation

/// Configuration conflicts are checked before writing. The operating system's
/// atomic bind remains authoritative for occupied ports and concurrent processes.
public enum TunnelEndpoints {
    public struct Listener: Equatable, Sendable {
        public var bind: String
        public var port: Int
        public var remote: Bool
    }

    public static func listener(_ profile: TunnelProfile) -> Listener {
        switch profile.kind {
        case .local(let bind, let port, _, _), .dynamic(let bind, let port):
            return Listener(bind: bind, port: port, remote: false)
        case .remote(let bind, let port, _, _):
            return Listener(bind: bind, port: port, remote: true)
        }
    }

    public static func conflict(for profile: TunnelProfile, among profiles: [TunnelProfile]) -> TunnelProfile? {
        let endpoint = listener(profile)
        guard endpoint.port > 0 else { return nil }
        return profiles.first { other in
            guard other.id != profile.id else { return false }
            let candidate = listener(other)
            guard endpoint.remote == candidate.remote, endpoint.port == candidate.port else { return false }
            if endpoint.remote && profile.sessionID != other.sessionID { return false }
            let a = endpoint.bind.lowercased(), b = candidate.bind.lowercased()
            let wildcards: Set<String> = ["", "*", "0.0.0.0", "::"]
            let loopbacks: Set<String> = ["localhost", "127.0.0.1", "::1"]
            return a == b || wildcards.contains(a) || wildcards.contains(b)
                || (loopbacks.contains(a) && loopbacks.contains(b))
        }
    }

    /// Only a local HTTP(S) listener is a browser destination. Wildcard binds
    /// become loopback URLs; the protocol is a fixed whitelist, not user input.
    public static func browserURL(for profile: TunnelProfile) -> URL? {
        guard case .local(let bind, let port, _, _) = profile.kind,
              let service = profile.service, service != .tcp,
              (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = service.rawValue
        let host = ["", "*", "0.0.0.0", "::"].contains(bind) ? "127.0.0.1" : bind
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port
        components.path = "/"
        return components.url
    }
}
