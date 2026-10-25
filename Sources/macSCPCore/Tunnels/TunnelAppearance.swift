import Foundation

/// Uses the same icon catalogue as connections; never changes routing or authentication.
public struct TunnelAppearance: Codable, Hashable, Sendable {
    public typealias Icon = SessionAppearance.Icon

    public var icon: Icon
    public var tint: SessionAppearance.Tint
    public var applicationLogo: String?

    public init(icon: Icon = .automatic, tint: SessionAppearance.Tint = .blue, applicationLogo: String? = nil) {
        self.icon = icon
        self.tint = tint
        self.applicationLogo = applicationLogo
    }
}
