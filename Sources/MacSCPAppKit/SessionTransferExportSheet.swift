import SwiftUI
import macSCPCore

/// One format selector for menu and context-menu exports. Native MacSCP
/// remains the default; each exporter retains its own validation policy.
struct SessionTransferExportSheet: View {
    let viewModel: SessionListViewModel
    let scope: SessionListViewModel.ExportScope
    let onExport: (SessionExportOptions) -> String?
    @State private var format: Format = .macscp

    private enum Format: Hashable { case macscp, winscp }

    private var scopedIDs: Set<UUID> {
        switch scope {
        case .all: Set(viewModel.sessions.map(\.id))
        case .single(let session): [session.id]
        case .group(let group): Set(viewModel.sessions(inGroup: group.id).map(\.id))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.string("transfer.format", "Format"), selection: $format) {
                Text(L10n.string("transfer.macscp", "MacSCP (default)")).tag(Format.macscp)
                Text(L10n.string("transfer.winscp", "WinSCP")).tag(Format.winscp)
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            switch format {
            case .macscp:
                SessionExportSheet(viewModel: viewModel, scope: scope, onExport: onExport)
            case .winscp:
                WinSCPTransferSheet(action: .exportFile, sessions: viewModel, exportSessionIDs: scopedIDs) { _ in }
            }
        }
    }
}
