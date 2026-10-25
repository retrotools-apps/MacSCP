import SwiftUI
import macSCPCore

struct FileInspectionRequest: Identifiable {
    let id = UUID()
    let path: String
    var editing = false
}

struct RemoteDirectorySearchSheet: View {
    let source: any RemoteFileSystem
    let path: String
    let fileWindows: FileInspectionWindows
    @State private var query = ""
    @State private var mode: RemoteDirectorySearchMode = .name
    @State private var results: [String] = []
    @State private var errorMessage: String?
    @State private var searched = false
    @State private var running: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("filetools.remoteSearch", "Search remote folder")).font(.headline)
            Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Picker(L10n.string("filetools.searchMode", "Search by"), selection: $mode) {
                Text(L10n.string("filetools.searchNames", "File name contains")).tag(RemoteDirectorySearchMode.name)
                Text(L10n.string("filetools.searchContents", "File contents contain")).tag(RemoteDirectorySearchMode.contents)
            }.pickerStyle(.segmented).disabled(running != nil)
            HStack {
                TextField(L10n.string("filetools.search", "Find text"), text: $query)
                    .onSubmit { search() }.disabled(running != nil)
                Button(L10n.string("filetools.go", "Go")) { search() }.disabled(query.isEmpty || running != nil)
                if running != nil {
                    ProgressView().controlSize(.small)
                    Button(L10n.string("common.cancel", "Cancel")) { running?.cancel() }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if searched && results.isEmpty && running == nil && errorMessage == nil {
                Text(L10n.string("filetools.notFound", "No match found.")).foregroundStyle(.secondary)
            }
            List(Array(results.enumerated()), id: \.offset) { _, result in
                Button { fileWindows.open(source: source, path: result) } label: {
                    Text(result).font(.system(.body, design: .monospaced)).lineLimit(2)
                }.buttonStyle(.plain)
            }
            HStack {
                Text(String(results.count)).monospacedDigit()
                Spacer()
                Button(L10n.string("common.close", "Close")) { dismiss() }
            }
        }
        .padding(16).frame(minWidth: 720, minHeight: 480)
        .onDisappear { running?.cancel() }
    }

    private func search() {
        guard running == nil, !query.isEmpty else { return }
        results = []; errorMessage = nil; searched = true
        let query = query, mode = mode
        running = Task {
            defer { running = nil }
            do {
                guard let searcher = source as? any RemoteDirectorySearching else { throw FileToolError.unsupported }
                let found = try await searcher.searchDirectory(path: path, query: query, mode: mode)
                try Task.checkCancellation()
                results = DisplayNameOrder.sorted(found, by: { $0 })
            } catch is CancellationError { searched = false }
            catch { errorMessage = FileToolLabels.error(error) }
        }
    }
}
