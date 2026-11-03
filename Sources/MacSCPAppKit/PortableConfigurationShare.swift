import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// A file promised to the native macOS sharing picker. `ShareLink` turns
/// this representation into the standard AirDrop/Mail/Messages menu and
/// also exposes third-party sharing extensions installed on the Mac.
struct PortableConfigurationShareItem: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .macscpConfiguration) { item in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("macscp-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(item.filename)
            try item.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    @MainActor static func make(
        name: String, scope: SessionListViewModel.ExportScope,
        viewModel: SessionListViewModel,
        tunnels: [TunnelProfile], tunnelGroups: [TunnelGroup]
    ) -> PortableConfigurationShareItem? {
        let connections = viewModel.exportPayload(
            for: scope, includeGroups: true, includePasswords: false).payload
        guard !connections.sessions.isEmpty else { return nil }
        let archive = MacSCPArchiveBuilder.build(
            scope: manifestScope(scope), connections: connections,
            includeIdentities: false, tunnels: tunnels, tunnelGroups: tunnelGroups)
        guard let data = try? MacSCPArchiveCodec.encode(archive, password: nil) else { return nil }
        return PortableConfigurationShareItem(
            data: data, filename: safeFilename(name) + "." + MacSCPArchiveCodec.fileExtension)
    }

    private static func manifestScope(
        _ scope: SessionListViewModel.ExportScope
    ) -> MacSCPArchiveManifest.Scope {
        switch scope {
        case .single: .connection
        case .group: .group
        case .all: .all
        }
    }

    private static func safeFilename(_ requested: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0").union(.newlines)
        let pieces = requested.components(separatedBy: invalid).filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "MacSCP Configuration" : joined
    }
}
