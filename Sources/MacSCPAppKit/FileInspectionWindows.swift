import AppKit
import SwiftUI
import macSCPCore

/// Owned by a session tab, not by its transient browser views. Switching tabs
/// keeps documents open; connection teardown closes their readers explicitly.
@MainActor
final class FileInspectionWindows {
    private(set) var documents: [FileInspectionWindowController] = []

    func open(source: any RemoteFileSystem, path: String, editing: Bool = false) {
        let document = FileInspectionWindowController(source: source, path: path, editing: editing)
        documents.append(document)
        document.onClosed = { [weak self, weak document] in
            self?.documents.removeAll { $0 === document }
        }
        document.showWindow(nil)
        document.window?.makeKeyAndOrderFront(nil)
    }

    func closeAll() async {
        let closing = documents
        documents.removeAll()
        for document in closing { await document.shutdown() }
    }
}

@MainActor
final class FileInspectionWindowController: NSWindowController, NSWindowDelegate {
    let model: FileInspectionModel
    var onClosed: (() -> Void)?
    private var opening: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var closing: Task<Void, Never>?

    init(source: any RemoteFileSystem, path: String, editing: Bool) {
        model = FileInspectionModel(source: source, path: path, editing: editing)
        let window = FileInspectionWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "\(L10n.string(editing ? "commander.edit" : "filetools.view", editing ? "Edit" : "View")) — \((path as NSString).lastPathComponent)"
        window.contentMinSize = NSSize(width: 640, height: 380)
        super.init(window: window)
        window.document = self
        window.delegate = self
        window.contentView = NSHostingView(rootView: FileInspectionSheet(model: model, onClose: { [weak self] in
            self?.window?.performClose(nil)
        }, onSave: { [weak self] in self?.save() }, onView: { [weak self] in
            guard let self else { return }
            self.opening = Task { [model] in await model.openAsViewer() }
        }))
        window.center()
        opening = Task { [model] in await model.open() }
    }

    required init?(coder: NSCoder) { nil }

    func save() {
        guard saving == nil, !model.busy, model.dirty else { return }
        saving = Task { [self] in
            await model.save()
            saving = nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A pending save must finish before its connection or window is closed.
        guard saving == nil else { return false }
        guard model.dirty else { return true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.string("filetools.discard", "Discard unsaved changes?")
        alert.addButton(withTitle: L10n.string("common.cancel", "Cancel"))
        alert.addButton(withTitle: L10n.string("filetools.discardAction", "Discard changes"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.window?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closing = Task { [self] in
            await finishOperations()
            onClosed?()
        }
    }

    private func finishOperations() async {
        opening?.cancel()
        await opening?.value
        opening = nil
        await saving?.value
        await model.close()
    }

    func shutdown() async {
        // Teardown is explicit even if the SwiftUI content never appeared.
        window?.close()
        if let closing { await closing.value }
        else { await finishOperations() }
    }
}

/// These windows are hosted by AppKit, outside a SwiftUI WindowGroup. Route
/// document shortcuts locally rather than relying on a scene's command bridge.
@MainActor
final class FileInspectionWindow: NSWindow {
    weak var document: FileInspectionWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let document else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command {
            switch key {
            case "w": performClose(nil); return true
            case "s" where document.model.editing: document.save(); return true
            case "f" where !document.model.editing: document.model.searchFocusToken += 1; return true
            case "g" where !document.model.editing: document.model.findNext(); return true
            default: break
            }
        } else if modifiers == [.command, .shift], key == "g", !document.model.editing {
            document.model.findPrevious()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct FileInspectionActions {
    var view: (() -> Void)?
    var edit: (() -> Void)?
}

private struct FileInspectionActionsKey: FocusedValueKey {
    typealias Value = FileInspectionActions
}

extension FocusedValues {
    var fileInspectionActions: FileInspectionActions? {
        get { self[FileInspectionActionsKey.self] }
        set { self[FileInspectionActionsKey.self] = newValue }
    }
}

extension ContentView {
    var fileInspectionActions: FileInspectionActions {
        let tab = activeTab
        guard !tab.isDisconnecting else { return .init() }
        if let pair = tab.remotePair, let peers = pair.liveTabs {
            let owner = peers.left.commanderActiveSide == .local ? peers.left : peers.right
            guard let session = owner.session else { return .init() }
            return Self.inspectionActions(browser: session.remote, source: session.remoteFS, windows: owner.fileWindows)
        }
        guard let session = tab.session else { return .init() }
        return Self.inspectionActions(browser: tab.commanderActiveSide == .local ? session.local : session.remote,
            source: tab.commanderActiveSide == .local ? session.localFS : session.remoteFS, windows: tab.fileWindows)
    }

    static func inspectionActions(browser: RemoteBrowserViewModel, source: any RemoteFileSystem,
                                  windows: FileInspectionWindows) -> FileInspectionActions {
        guard browser.state == .loaded, browser.selectedItems.count == 1,
              let file = browser.selectedItems.first, file.kind == .file else { return .init() }
        return .init(view: source is any WindowedFileAccess ? { windows.open(source: source, path: file.path) } : nil,
                     edit: { windows.open(source: source, path: file.path, editing: true) })
    }
}
