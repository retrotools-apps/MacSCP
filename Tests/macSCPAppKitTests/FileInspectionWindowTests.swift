import AppKit
import Testing
import macSCPCore
@testable import MacSCPAppKit

@Suite("File document windows", .serialized, .timeLimit(.minutes(1)))
@MainActor struct FileInspectionWindowTests {
    @Test func documentsUseIndependentResizableWindowsAndExplicitCleanup() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("document-\(UUID()).txt")
        try Data("Demonstration text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = FileInspectionWindows()
        owner.open(source: LocalFileSystem(), path: url.path)
        owner.open(source: LocalFileSystem(), path: url.path, editing: true)
        #expect(owner.documents.count == 2)
        let documents = owner.documents
        for document in documents {
            let window = try #require(document.window)
            #expect(window.styleMask.contains([.titled, .closable, .resizable, .miniaturizable]))
            #expect(window.sheetParent == nil)
            #expect(window.tabbingMode == .disallowed)
            let before = window.frame
            window.setFrame(before.offsetBy(dx: 20, dy: 20), display: false)
            #expect(window.frame.origin != before.origin)
            let content = try #require(window.contentView)
            let originalContentSize = content.bounds.size
            var larger = window.frame
            larger.size.width += 120
            larger.size.height += 120
            window.setFrame(larger, display: false)
            content.layoutSubtreeIfNeeded()
            #expect(content.bounds.width > originalContentSize.width)
            #expect(content.bounds.height > originalContentSize.height)
        }
        #expect(documents[0].window !== documents[1].window)
        await owner.closeAll()
        #expect(owner.documents.isEmpty)
        #expect(documents.allSatisfy { !$0.model.ready && $0.window?.isVisible == false })
    }

    @Test func menuActionsFollowLoadedRegularFileSelectionAndBackendCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-menu-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Text".utf8).write(to: directory.appendingPathComponent("sample.txt"))
        let fs = LocalFileSystem()
        let browser = RemoteBrowserViewModel(fs: fs, startPath: directory.path)
        let windows = FileInspectionWindows()
        #expect(ContentView.inspectionActions(browser: browser, source: fs, windows: windows).edit == nil)
        await browser.load()
        browser.selectedItems = [try #require(browser.items.first { $0.name == "sample.txt" })]
        let actions = ContentView.inspectionActions(browser: browser, source: fs, windows: windows)
        #expect(actions.view != nil)
        #expect(actions.edit != nil)
        browser.selectedItems = []
        #expect(ContentView.inspectionActions(browser: browser, source: fs, windows: windows).view == nil)
    }

    @Test func documentShortcutsSaveAndCloseOnlyTheirOwnWindow() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("document-keys-\(UUID()).txt")
        try Data("Original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = FileInspectionWindows()
        owner.open(source: LocalFileSystem(), path: url.path, editing: true)
        let document = try #require(owner.documents.first)
        let window = try #require(document.window)
        while !document.model.ready && document.model.errorMessage == nil { await Task.yield() }
        #expect(document.model.errorMessage == nil)
        document.model.text = "Updated"
        let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        let handledSave = window.performKeyEquivalent(with: save)
        #expect(handledSave)
        guard handledSave else { await owner.closeAll(); return }
        while document.model.dirty && document.model.errorMessage == nil { await Task.yield() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "Updated")
        let close = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: close))
        #expect(!window.isVisible)
        await owner.closeAll()
    }

    @Test func closingAModifiedEditorRequiresAnExplicitDiscard() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("document-discard-\(UUID()).txt")
        try Data("Original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = FileInspectionWindows()
        owner.open(source: LocalFileSystem(), path: url.path, editing: true)
        let document = try #require(owner.documents.first)
        let window = try #require(document.window)
        while !document.model.ready && document.model.errorMessage == nil { await Task.yield() }
        document.model.text = "Unsaved changes"
        #expect(!document.windowShouldClose(window))
        let question = try #require(window.attachedSheet)
        #expect(window.isVisible)
        window.endSheet(question, returnCode: .alertFirstButtonReturn)
        await Task.yield()
        #expect(document.model.dirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Original")
        await owner.closeAll()
    }
}
