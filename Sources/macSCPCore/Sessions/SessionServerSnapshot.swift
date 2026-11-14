import Crypto
import Foundation

/// A dated inventory, deliberately excluding live utilization and credentials.
public struct SessionServerSnapshot: Codable, Sendable, Equatable {
    public struct Capacity: Codable, Sendable, Equatable {
        public let device: String
        public let mount: String
        public let totalBytes: UInt64
    }
    public let collectedAt: Date
    public let identity: String
    public let os: String?
    public let accounts: UInt64?
    public var accountScope: String? = nil
    public let memoryBytes: UInt64?
    public let volumes: [Capacity]
    public let storageDevices: [ServerNetworkAddresses.StorageDevice]
    public var groupedStorage: Bool? = nil
    public let addresses: [ServerNetworkAddresses.InterfaceAddress]
    public let publicIPv4: String?
    public let publicIPv6: String?

    public init(session: StoredSession, information: ServerNetworkAddresses, collectedAt: Date = Date()) {
        self.collectedAt = collectedAt
        identity = Self.identity(for: session)
        os = information.system["os"]
        accounts = information.system["users"].flatMap { value in
            let fields = value.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 ? UInt64(fields[1]) : nil
        }
        accountScope = information.system["account-scope"]
        memoryBytes = information.system["memory"].flatMap { value in
            let fields = value.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 ? UInt64(fields[1]) : nil
        }
        if let summary = information.storageSummary {
            groupedStorage = true
            volumes = summary.map { Capacity(device: $0.name, mount: $0.name, totalBytes: $0.totalBytes) }
            storageDevices = []
        } else {
            volumes = information.volumes.map { Capacity(device: $0.device, mount: $0.mount, totalBytes: $0.totalBytes) }
            storageDevices = information.storageDevices
        }
        addresses = information.local
        publicIPv4 = information.publicIPv4
        publicIPv6 = information.publicIPv6
    }

    static func identity(for session: StoredSession) -> String {
        let fields = [session.ssh?.host ?? "", String(session.ssh?.port ?? 22), session.ssh?.username ?? "",
                      session.jump?.host ?? "", String(session.jump?.port ?? 22)]
        return SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func capacityText(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var value = Double(bytes), unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}

/// Local inventory cache, separate from portable session files and exports.
public struct SessionServerSnapshotStore: Sendable {
    private let directory: URL
    public init(directory: URL = SessionStore.defaultDirectory) {
        self.directory = directory.appendingPathComponent("server-snapshots", isDirectory: true)
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func load(for session: StoredSession) -> SessionServerSnapshot? {
        guard session.kind == .ssh, let data = try? Data(contentsOf: file(session.id)), data.count <= 262_144,
              let snapshot = try? JSONDecoder().decode(SessionServerSnapshot.self, from: data),
              snapshot.identity == SessionServerSnapshot.identity(for: session) else { return nil }
        return snapshot
    }

    public func delete(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: file(sessionID))
    }

    public func save(_ snapshot: SessionServerSnapshot, for session: StoredSession) {
        guard session.kind == .ssh, snapshot.identity == SessionServerSnapshot.identity(for: session),
              let data = try? JSONEncoder().encode(snapshot), data.count <= 262_144 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: file(session.id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(session.id).path)
        } catch { /* Inventory persistence must not fail a diagnosis. */ }
    }
}
