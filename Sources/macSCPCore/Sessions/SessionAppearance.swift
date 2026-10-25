import Foundation

/// Secret-free display preferences, independent of connection configuration.
/// Unknown catalogue entries fall back safely when opening a newer export.
public struct SessionAppearance: Codable, Equatable, Sendable {
    public enum Icon: String, CaseIterable, Codable, Sendable {
        case automatic, server, database, bastion, firewall, router, networkSwitch
        case ai, web, storage, cloud, desktop, laptop, backup, mail, container
        case api, dns, media, device, honeypot, analyzer, mobile, robot
        case internetBox, ghost
        case secureWeb, remoteDesktop, ssh, files, monitoring, logs, directory, messaging
        case vmwareESXi, kibana, redis, mysql, apache, php, tomcat
        case nginx, postgresql, mongodb, elasticsearch, grafana, prometheus
        case docker, kubernetes, gitlab, jenkins

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .automatic
        }
    }

    public enum Tint: String, CaseIterable, Codable, Sendable {
        case blue, teal, green, orange, red, purple, pink, gray

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .blue
        }
    }

    public var icon: Icon
    public var tint: Tint
    /// Optional catalogue identifier, never a file path or remote URL.
    public var applicationLogo: String?

    public init(icon: Icon = .automatic, tint: Tint = .blue, applicationLogo: String? = nil) {
        self.icon = icon
        self.tint = tint
        self.applicationLogo = applicationLogo
    }
}
