import Foundation
@testable import macSCPCore

/// Test-only adapter for connection-payload tests. Production exposes only
/// `MacSCPArchiveCodec`.
enum ConnectionSectionTestCodec {
    static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data {
        try MacSCPArchiveCodec.encode(
            MacSCPArchiveBuilder.build(
                scope: .all, connections: payload, includeIdentities: true,
                tunnels: [], tunnelGroups: []),
            password: password)
    }

    static func probe(_ data: Data) throws -> Bool { try MacSCPArchiveCodec.probe(data) }

    static func decode(
        _ data: Data, password: String? = nil
    ) throws -> SessionExportPayload {
        guard let payload = try MacSCPArchiveCodec.decode(data, password: password).connections else {
            throw SessionExportError.notAnExportFile
        }
        return payload
    }
}
