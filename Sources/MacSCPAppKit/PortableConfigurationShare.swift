import AppKit
import Foundation
import macSCPCore

/// The portable file handed to the native macOS sharing picker.
///
/// This is deliberately a plain value rather than a `Transferable` used by a
/// `ShareLink`. SwiftUI constructs context-menu links while evaluating a row,
/// and row hover changes reevaluate that body. On macOS that eagerly creates
/// ShareKit pickers and can stall pointer handling. The picker below is built
/// only after the user explicitly chooses Share.
struct PortableConfigurationShareItem {
    let data: Data
    let filename: String

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

@MainActor
enum PortableConfigurationSharer {
    static func show(_ item: PortableConfigurationShareItem) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let anchor = window.contentView,
              let url = try? writeTemporaryFile(item) else {
            NSSound.beep()
            return
        }

        // Let the context menu dismiss before presenting its replacement.
        DispatchQueue.main.async {
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let anchorPoint = anchor.convert(windowPoint, from: nil)
            let picker = NSSharingServicePicker(items: [url])
            picker.show(
                relativeTo: NSRect(origin: anchorPoint, size: .zero),
                of: anchor,
                preferredEdge: .minY)
        }
    }

    private static func writeTemporaryFile(_ item: PortableConfigurationShareItem) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(item.filename)
        try item.data.write(to: url, options: .atomic)
        return url
    }
}
