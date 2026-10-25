import AppKit
import Observation
import SwiftUI
import macSCPCore

enum FileToolLabels {
    static func error(_ error: any Error) -> String {
        switch error as? FileToolError {
        case .unsupported: return L10n.string("filetools.unsupported", "This server does not support windowed file access.")
        case .textOnly: return L10n.string("filetools.textOnly", "Binary or non-UTF-8 content: use the hexadecimal viewer instead.")
        case .editorSizeLimit: return L10n.string("filetools.editLimit", "The text editor is limited to 8 MiB. Use the windowed viewer for larger files.")
        case .changed: return L10n.string("filetools.changed", "The file changed on the server. Reopen it before saving.")
        case .resultsTooLarge: return L10n.string("filetools.resultsLimit", "Too many results. Narrow the search or choose a smaller folder.")
        case .searchUnavailable: return L10n.string("filetools.searchUnavailable", "Remote file search requires Python 3 on the SSH server. No local download fallback is used.")
        default: return L10n.string("filetools.failed", "The operation failed. Check the connection, path and permissions.")
        }
    }
}

@Observable @MainActor
final class FileInspectionModel {
    let source: any RemoteFileSystem
    let path: String
    private(set) var editing: Bool
    var text = ""
    var originalText = ""
    var data = Data()
    var size: UInt64 = 0
    var offset: UInt64 = 0
    var hexadecimal = false { didSet { updateDisplay() } }
    private(set) var displayed = ""
    var busy = false
    private(set) var ready = false
    var errorMessage: String?
    var query = "" { didSet { if query != oldValue { resetSearch() } } }
    var searchStatus = ""
    var searchFocusToken = 0
    var searchTask: Task<Void, Never>?
    private var reader: (any ByteWindowReader)?
    private var original: RemoteFileItem?
    private var preservesBOM = false
    private var matchOffset: UInt64?

    var selectedRanges: [NSRange] {
        guard matchOffset == offset, matchOffset != nil, !query.isEmpty else { return [] }
        if !hexadecimal { return [NSRange(location: 0, length: query.utf16.count)] }
        let count = query.utf8.count
        return stride(from: 0, to: count, by: 16).map {
            NSRange(location: ($0 / 16) * 84 + 18, length: min(16, count - $0) * 3 - 1)
        }
    }

    init(source: any RemoteFileSystem, path: String, editing: Bool) {
        self.source = source; self.path = path; self.editing = editing
    }
    var dirty: Bool { editing && text != originalText }
    private func updateDisplay() {
        displayed = hexadecimal ? FileWindow.hex(data, offset: offset) : String(decoding: data, as: UTF8.self)
    }

    func open() async {
        ready = false; errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            let item = try await source.stat(path: path)
            guard item.kind == .file, let length = item.size else { throw FileToolError.unsupported }
            if editing, length > UInt64(FileTextCodec.maximumBytes) { throw FileToolError.editorSizeLimit }
            original = item; size = length
            if let windowed = source as? any WindowedFileAccess {
                let opened = try await windowed.openWindowedFile(path: path)
                if Task.isCancelled { await opened.close(); return }
                reader = opened
            } else if !editing { throw FileToolError.unsupported }
            if editing {
                var bytes = Data()
                if let reader {
                    while UInt64(bytes.count) < length {
                        try Task.checkCancellation()
                        let count = Int(min(UInt64(FileWindow.size), length - UInt64(bytes.count)))
                        let chunk = try await reader.read(offset: UInt64(bytes.count), count: count)
                        guard !chunk.isEmpty, chunk.count <= count else { throw FileToolError.changed }
                        bytes.append(chunk)
                    }
                } else {
                    // Small editable documents may be downloaded, unlike the
                    // viewer. Never start a stream for a file above the cap.
                    let stream = try await source.readStream(path: path, fromOffset: 0)
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        guard chunk.count <= FileTextCodec.maximumBytes - bytes.count else {
                            throw FileToolError.editorSizeLimit
                        }
                        bytes.append(chunk)
                    }
                    guard UInt64(bytes.count) == length else { throw FileToolError.changed }
                }
                preservesBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
                if preservesBOM { bytes.removeFirst(3) }
                text = try FileTextCodec.decode(bytes)
                originalText = text
            } else {
                guard let reader else { throw FileToolError.unsupported }
                data = try await reader.read(offset: 0, count: Int(min(UInt64(FileWindow.size), size)))
                hexadecimal = FileWindow.isBinary(data, allowingIncompleteUTF8Suffix: UInt64(data.count) < size)
                updateDisplay()
            }
            try Task.checkCancellation()
            ready = true
        } catch {
            let opened = reader; reader = nil
            await opened?.close()
            if !(error is CancellationError) { errorMessage = FileToolLabels.error(error) }
        }
    }

    func findNext() { find(.forward) }
    func findPrevious() { find(.backward) }

    private func find(_ direction: FileSearchDirection) {
        guard ready, !editing, !busy, !query.isEmpty else { return }
        busy = true; errorMessage = nil
        searchStatus = L10n.string("filetools.searching", "Searching…")
        let source = source, path = path, query = query, match = matchOffset
        searchTask = Task {
            // Conversion and scanning stay off the UI actor. The SSH backend
            // searches remotely and returns only the matched display window.
            let worker = Task.detached(priority: .userInitiated) {
                guard let searcher = source as? any FileWindowSearching else { throw FileToolError.unsupported }
                let result = try await searcher.searchWindow(path: path, query: Data(query.utf8),
                    direction: direction, relativeTo: match)
                if result == nil, match != nil {
                    try Task.checkCancellation()
                    let wrapped = try await searcher.searchWindow(path: path, query: Data(query.utf8),
                        direction: direction, relativeTo: nil)
                    return (wrapped, true)
                }
                return (result, false)
            }
            defer { busy = false; searchTask = nil }
            do {
                let (result, wrapped) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard ready, self.query == query else { return }
                if let result {
                    matchOffset = result.offset
                    data = result.data; offset = result.offset; size = result.size
                    updateDisplay()
                    searchStatus = wrapped
                        ? L10n.string("filetools.searchWrapped", "Search wrapped around to a match.")
                        : L10n.string("filetools.matchFound", "Match found.")
                } else {
                    matchOffset = nil
                    searchStatus = L10n.string("filetools.notFound", "No match found.")
                }
            } catch is CancellationError { searchStatus = "" }
            catch { searchStatus = ""; errorMessage = FileToolLabels.error(error) }
        }
    }
    func resetSearch() { searchTask?.cancel(); matchOffset = nil; searchStatus = "" }

    func save() async {
        guard ready, editing, !busy, let original else { return }
        busy = true
        let savingText = text
        defer { busy = false }
        do {
            var bytes = Data(savingText.utf8)
            if preservesBOM { bytes.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
            guard bytes.count <= FileTextCodec.maximumBytes else { throw FileToolError.editorSizeLimit }
            let current = try await source.stat(path: path)
            guard current.kind == .file, current.size == original.size,
                  current.modifiedAt == original.modifiedAt else { throw FileToolError.changed }
            try await source.write(path: path, mode: .overwrite, contents: FileTextCodec.stream(bytes))
            self.original = try await source.stat(path: path)
            originalText = savingText; errorMessage = nil
        } catch is CancellationError {} catch { errorMessage = FileToolLabels.error(error) }
    }

    func close() async {
        ready = false
        let searching = searchTask
        searching?.cancel()
        await searching?.value
        let opened = reader; reader = nil
        await opened?.close()
    }

    func openAsViewer() async {
        await close()
        editing = false
        await open()
    }
}

/// AppKit text storage avoids SwiftUI laying out one view per character or
/// byte. The viewer receives only one bounded window, never the whole file.
struct FileToolTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var selectedRanges: [NSRange] = []
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true
        view.allowsUndo = editable
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        let replaced = view.string != text
        if replaced { view.string = text; view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
        if !editable, replaced || context.coordinator.searchRanges != selectedRanges {
            let ranges = selectedRanges.isEmpty ? [NSRange(location: 0, length: 0)] : selectedRanges
            view.selectedRanges = ranges.map { NSValue(range: $0) }
            if let first = selectedRanges.first { view.scrollRangeToVisible(first) }
            context.coordinator.searchRanges = selectedRanges
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FileToolTextView
        var searchRanges: [NSRange] = []
        init(parent: FileToolTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}

struct FileInspectionSheet: View {
    @Bindable var model: FileInspectionModel
    let onClose: () -> Void
    let onSave: () -> Void
    let onView: () -> Void
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.path).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.editing {
                    Button(L10n.string("common.save", "Save"), action: onSave)
                        .keyboardShortcut("s", modifiers: .command).disabled(model.busy || !model.dirty)
                }
                Button(L10n.string("common.close", "Close")) {
                    onClose()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            if !model.editing {
                HStack {
                    TextField(L10n.string("filetools.search", "Find text"), text: $model.query)
                        .focused($searchFocused)
                        .disabled(model.busy || !model.ready)
                        .onSubmit { model.findNext() }
                    Button(L10n.string("filetools.previous", "Previous")) { model.findPrevious() }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .help(L10n.string("filetools.findPrevious", "Find previous"))
                        .disabled(model.busy || !model.ready || model.query.isEmpty)
                    Button(L10n.string("filetools.next", "Next")) { model.findNext() }
                        .keyboardShortcut("g", modifiers: .command)
                        .help(L10n.string("filetools.findNext", "Find next"))
                        .disabled(model.busy || !model.ready || model.query.isEmpty)
                    if model.searchTask != nil {
                        Button(L10n.string("common.cancel", "Cancel")) { model.searchTask?.cancel() }
                    }
                    Toggle(L10n.string("filetools.hex", "Hexadecimal"), isOn: $model.hexadecimal)
                    Button(L10n.string("filetools.search", "Find text")) { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden().frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if model.editing && !model.ready && !model.busy {
                Button(L10n.string("filetools.view", "View"), action: onView)
            }
            if !model.searchStatus.isEmpty { Text(model.searchStatus).font(.caption).monospacedDigit() }
            FileToolTextView(text: model.editing ? $model.text : .constant(model.displayed),
                editable: model.editing && model.ready && !model.busy, selectedRanges: model.selectedRanges)
                .border(Color.secondary.opacity(0.2))
        }
        .padding(16).frame(minWidth: 640, minHeight: 380, maxHeight: .infinity)
        .onChange(of: model.searchFocusToken) { _, _ in searchFocused = true }
    }
}
