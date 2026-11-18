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
    private(set) var previewTask: Task<Void, Never>?
    private(set) var previewRevision = 0
    private(set) var previewPlacement: Double = 0
    private var reader: (any ByteWindowReader)?
    private var original: RemoteFileItem?
    private var preservesBOM = false
    private var matchOffset: UInt64?
    private var showsMatch = false
    private var pendingPreview: PreviewRequest?

    private struct PreviewRequest: Equatable {
        let offset: UInt64
        let count: Int
        let placement: Double
    }

    var selectedRanges: [NSRange] {
        guard showsMatch, matchOffset == offset, !query.isEmpty else { return [] }
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
                data = try await Self.readPreview(reader, offset: 0, count: Int(min(UInt64(FileWindow.size), size)))
                hexadecimal = FileWindow.isBinary(data, allowingIncompleteUTF8Suffix: UInt64(data.count) < size)
            }
            try Task.checkCancellation()
            ready = true
        } catch {
            let opened = reader; reader = nil
            await opened?.close()
            if !(error is CancellationError) { errorMessage = FileToolLabels.error(error) }
        }
    }

    func movePreviewWindow(forward: Bool) {
        guard previewTask == nil else { return }
        let windowSize = UInt64(FileWindow.size)
        if forward {
            let end = offset + UInt64(data.count)
            guard end < size else { return }
            requestPreview(.init(offset: end, count: Int(min(windowSize, size - end)), placement: 0))
        } else {
            let count = min(offset, windowSize)
            guard count > 0 else { return }
            requestPreview(.init(offset: offset - count, count: Int(count), placement: 1))
        }
    }

    func seekPreview(to fraction: Double, visibleBytes: Double) {
        guard size > 0 else { return }
        let count = min(size, UInt64(FileWindow.size))
        let lastStart = size - count
        if fraction >= 1 {
            requestPreview(.init(offset: lastStart, count: Int(count), placement: 1))
            return
        }
        let visible = min(Double(count), max(1, visibleBytes))
        let target = (Double(size) - visible) * max(0, fraction)
        let start = min(lastStart, UInt64(min(Double(lastStart), target)))
        let placement = min(1, max(0, target - Double(lastStart)) / max(1, Double(count) - visible))
        let request = PreviewRequest(offset: start, count: Int(min(UInt64(FileWindow.size), size - start)), placement: placement)
        requestPreview(request)
    }

    private func requestPreview(_ request: PreviewRequest) {
        guard ready, !editing, !busy, let reader else { return }
        pendingPreview = request
        guard previewTask == nil else { return }
        previewTask = Task {
            defer { previewTask = nil }
            while !Task.isCancelled, let request = pendingPreview {
                pendingPreview = nil
                do {
                    let bytes = request.offset == offset && request.count == data.count
                        ? data : try await Self.readPreview(reader, offset: request.offset, count: request.count)
                    try Task.checkCancellation()
                    // A thumb drag can submit new positions during an SFTP read.
                    // Only the latest destination is presented.
                    if let pendingPreview, pendingPreview != request { continue }
                    pendingPreview = nil
                    data = bytes
                    offset = request.offset
                    showsMatch = false
                    previewPlacement = request.placement
                    previewRevision += 1
                    errorMessage = nil
                    updateDisplay()
                } catch is CancellationError {
                    return
                } catch {
                    if pendingPreview == nil { errorMessage = FileToolLabels.error(error) }
                }
            }
        }
    }

    private static func readPreview(_ reader: any ByteWindowReader, offset: UInt64, count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            let remaining = count - bytes.count
            let chunk = try await reader.read(offset: offset + UInt64(bytes.count), count: remaining)
            guard !chunk.isEmpty else { throw FileToolError.changed }
            guard chunk.count <= remaining else { throw FileToolError.oversizedResponse }
            bytes.append(chunk)
        }
        return bytes
    }

    func findNext() { find(.forward) }
    func findPrevious() { find(.backward) }

    private func find(_ direction: FileSearchDirection) {
        guard ready, !editing, !busy, !query.isEmpty else { return }
        pendingPreview = nil
        let previewing = previewTask
        previewing?.cancel()
        busy = true; errorMessage = nil
        searchStatus = L10n.string("filetools.searching", "Searching…")
        let source = source, path = path, query = query, match = matchOffset
        searchTask = Task {
            defer { busy = false; searchTask = nil }
            await previewing?.value
            guard !Task.isCancelled else { searchStatus = ""; return }
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
            do {
                let (result, wrapped) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard ready, self.query == query else { return }
                if let result {
                    matchOffset = result.offset
                    showsMatch = true
                    data = result.data; offset = result.offset; size = result.size
                    previewPlacement = 0
                    previewRevision += 1
                    updateDisplay()
                    searchStatus = wrapped
                        ? L10n.string("filetools.searchWrapped", "Search wrapped around to a match.")
                        : L10n.string("filetools.matchFound", "Match found.")
                } else {
                    matchOffset = nil
                    showsMatch = false
                    searchStatus = L10n.string("filetools.notFound", "No match found.")
                }
            } catch is CancellationError { searchStatus = "" }
            catch { searchStatus = ""; errorMessage = FileToolLabels.error(error) }
        }
    }
    func resetSearch() { searchTask?.cancel(); matchOffset = nil; showsMatch = false; searchStatus = "" }

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
        pendingPreview = nil
        let previewing = previewTask
        previewing?.cancel()
        let searching = searchTask
        searching?.cancel()
        await previewing?.value
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

/// AppKit text storage lays out the editor buffer or the current preview window.
struct FileToolTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var selectedRanges: [NSRange] = []
    var preview: FilePreviewScrollView.Window?
    var seek: ((Double, Double) -> Void)?
    var moveWindow: ((Bool) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let scroll = preview == nil ? NSScrollView() : FilePreviewScrollView()
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
        context.coordinator.scroll = scroll
        if let preview = scroll as? FilePreviewScrollView { return preview.makeContainer() }
        return scroll
    }
    func updateNSView(_ root: NSView, context: Context) {
        context.coordinator.parent = self
        guard let scroll = context.coordinator.scroll, let view = scroll.documentView as? NSTextView else { return }
        let previewScroll = scroll as? FilePreviewScrollView
        let windowChanged = previewScroll?.fileWindow?.revision != preview?.revision
        let horizontalOffset = scroll.contentView.bounds.minX
        previewScroll?.fileWindow = preview
        previewScroll?.seek = seek
        previewScroll?.moveWindow = moveWindow
        view.isEditable = editable
        let replaced = view.string != text
        if replaced { view.string = text }
        if let previewScroll, let preview, replaced || windowChanged {
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            previewScroll.placeWindow(at: preview.placement, horizontalOffset: horizontalOffset)
        } else if replaced {
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        if !editable, windowChanged || replaced || context.coordinator.searchRanges != selectedRanges {
            let ranges = selectedRanges.isEmpty ? [NSRange(location: 0, length: 0)] : selectedRanges
            view.selectedRanges = ranges.map { NSValue(range: $0) }
            if let first = selectedRanges.first { view.scrollRangeToVisible(first) }
            context.coordinator.searchRanges = selectedRanges
        }
        previewScroll?.updateFileScroller()
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FileToolTextView
        var searchRanges: [NSRange] = []
        weak var scroll: NSScrollView?
        init(parent: FileToolTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let scroll = scroll as? FilePreviewScrollView else { return false }
            switch commandSelector {
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                scroll.scrollPageDown(nil)
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                scroll.scrollPageUp(nil)
            case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                scroll.scrollToBeginningOfDocument(nil)
            case #selector(NSResponder.scrollToEndOfDocument(_:)):
                scroll.scrollToEndOfDocument(nil)
            default: return false
            }
            return true
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
                if model.busy || model.previewTask != nil { ProgressView().controlSize(.small) }
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
            if model.editing {
                FileToolTextView(text: $model.text, editable: model.ready && !model.busy)
                    .border(Color.secondary.opacity(0.2))
            } else {
                FileToolTextView(text: .constant(model.displayed), editable: false, selectedRanges: model.selectedRanges,
                    preview: .init(offset: model.offset, count: model.data.count, size: model.size,
                        revision: model.previewRevision, placement: model.previewPlacement,
                        enabled: model.ready && !model.busy, loading: model.previewTask != nil),
                    seek: model.seekPreview, moveWindow: model.movePreviewWindow)
                    .border(Color.secondary.opacity(0.2))
            }
        }
        .padding(16).frame(minWidth: 640, minHeight: 380, maxHeight: .infinity)
        .onChange(of: model.searchFocusToken) { _, _ in searchFocused = true }
    }
}
