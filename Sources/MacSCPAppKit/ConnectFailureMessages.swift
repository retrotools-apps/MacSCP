import macSCPCore

enum ConnectFailureMessages {
    static func messages(for category: ConnectFailureCategory) -> (title: ConnectFailureContent.Message, body: ConnectFailureContent.Message)? {
        let title: String, body: String
        switch category {
        case .authentication:
            title = "Authentication failed"
            body = "The server rejected the credentials. Check the username, password or SSH key."
        case .jumpAuthentication:
            title = "Jump host authentication failed"
            body = "The intermediate host rejected the credentials. Check the jump host's username, password or SSH key."
        case .network:
            title = "Server unreachable"
            body = "The connection could not be established. Check the host, port, network and any configured tunnel."
        case .timeout:
            title = "Connection timed out"
            body = "The server did not respond in time. Check the network, firewall and any configured tunnel."
        case .nameResolution:
            title = "Server name not found"
            body = "The server name could not be resolved. Check the hostname and DNS or VPN connection."
        case .tls:
            title = "TLS connection failed"
            body = "The secure connection could not be established. Check the gateway, certificate and server name."
        case .hostKey:
            title = "SSH host key not trusted"
            body = "The server's SSH identity was not accepted. Verify its host key before reconnecting."
        case .key:
            title = "SSH key unavailable"
            body = "The SSH key could not be used. Check its path, passphrase and SSH agent."
        case .keychain:
            title = "Saved credentials unavailable"
            body = "The credential vault could not be accessed. Check the macOS authorization."
        case .unknown: return nil
        }
        let prefix = "connection.failed." + category.rawValue
        return (.init(key: prefix + ".title", fallback: title), .init(key: prefix + ".body", fallback: body))
    }
}
