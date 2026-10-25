import Foundation

/// A TLS byte transport for SSH, not an SSH jump login. No shell command or
/// credential is persisted. The destination's SSH host key is still verified.
public struct SSHTLSTunnelConfig: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let serverName: String
    public let verifyCertificate: Bool

    public init(host: String, port: Int = 443, serverName: String? = nil,
                verifyCertificate: Bool = true) throws {
        let name = serverName.flatMap { $0.isEmpty ? nil : $0 } ?? host
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 253 && !value.hasPrefix("-") &&
            value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0))
            }
        }
        guard valid(host), valid(name), (1...65535).contains(port) else {
            throw RemoteFSError.protocolError(reason: CoreL10n.string("core.connect.invalidTLSTunnel"))
        }
        self.host = host
        self.port = port
        self.serverName = name
        self.verifyCertificate = verifyCertificate
    }

    private enum CodingKeys: String, CodingKey { case host, port, serverName, verifyCertificate }

    /// Storage adapter only; runtime config and decoding validate before use.
    init(storedHost: String, port: Int, serverName: String, verifyCertificate: Bool = true) {
        self.host = storedHost
        self.port = port
        self.serverName = serverName.isEmpty ? storedHost : serverName
        self.verifyCertificate = verifyCertificate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(String.self, forKey: .host),
                      port: c.decodeIfPresent(Int.self, forKey: .port) ?? 443,
                      serverName: c.decodeIfPresent(String.self, forKey: .serverName),
                      verifyCertificate: c.decodeIfPresent(Bool.self, forKey: .verifyCertificate) ?? true)
    }
}
