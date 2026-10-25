import Foundation
import AppKit
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Built-in file inspection", .timeLimit(.minutes(1)))
@MainActor struct FileInspectionTests {
    private actor StreamOnly: RemoteFileSystem {
        let backing = LocalFileSystem()
        var reads = 0
        func list(path: String) async throws -> [RemoteFileItem] { try await backing.list(path: path) }
        func stat(path: String) async throws -> RemoteFileItem { try await backing.stat(path: path) }
        func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
            reads += 1
            return try await backing.readStream(path: path, fromOffset: offset)
        }
        func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
            try await backing.write(path: path, mode: mode, contents: contents)
        }
        func delete(path: String) async throws { try await backing.delete(path: path) }
        func createDirectory(at path: String) async throws { try await backing.createDirectory(at: path) }
        func rename(from: String, to: String) async throws { try await backing.rename(from: from, to: to) }
        func setPermissions(path: String, permissions: UInt32) async throws { try await backing.setPermissions(path: path, permissions: permissions) }
        func deleteTree(at path: String) async throws { try await backing.deleteTree(at: path) }
        func homeDirectoryPath() async throws -> String { "/" }
        func disconnect() async {}
    }

    @Test func theEditorSupportsStreamOnlyBackendsButTheViewerNeverFallsBackToADownload() async throws {
        let url = try fixture(Data("original".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StreamOnly()
        let model = FileInspectionModel(source: source, path: url.path, editing: true)
        await model.open()
        #expect(model.ready)
        #expect(await source.reads == 1)
        model.text = "edited"
        await model.save()
        #expect(model.errorMessage == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited")
        await model.close()
        let viewer = FileInspectionModel(source: source, path: url.path, editing: false)
        await viewer.open()
        #expect(!viewer.ready)
        #expect(viewer.errorMessage != nil)
        #expect(await source.reads == 1)
        await viewer.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_FILETOOLS_SSH_PORT"] != nil))
    func editorOpensAndSavesThroughTheRealSFTPSession() async throws {
        let port = try #require(Int(ProcessInfo.processInfo.environment["MACSCP_FILETOOLS_SSH_PORT"] ?? ""))
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent("editor-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: knownHosts) }
        let config = try SSHConnectionConfig(host: "127.0.0.1", port: port, username: "testuser", auth: .password("testpass"))
        let fs = try await CitadelFileSystem.connect(config: config, connectTimeout: .seconds(20),
            knownHosts: KnownHostsStore(directory: knownHosts), onUnknownHostKey: .asking { _ in true })
        let path = "/tmp/macscp-editor-" + UUID().uuidString
        let model = FileInspectionModel(source: fs, path: path, editing: true)
        do {
            try await fs.write(path: path, mode: .overwrite, contents: FileTextCodec.stream(Data("original\r\n".utf8)))
            await model.open()
            #expect(model.ready)
            #expect(model.text == "original\r\n")
            model.text = "é edited\r\n"
            await model.save()
            #expect(model.errorMessage == nil)
            #expect(!model.dirty)
            let reader = try await fs.openWindowedFile(path: path)
            let saved = try await reader.read(offset: 0, count: 128)
            await reader.close()
            #expect(saved == Data(model.text.utf8))
            await model.close()
            try await fs.delete(path: path)
            await fs.disconnect()
        } catch {
            await model.close()
            try? await fs.delete(path: path)
            await fs.disconnect()
            throw error
        }
    }

    @Test func f3DispatchIsReadOnlyAndRequiresOneRegularFile() {
        let coordinator = RemoteFileTableView.Coordinator(onOpen: { _ in }, onSelect: { _ in }, side: .remote)
        let file = RemoteFileItem(name: "a", path: "/a", kind: .file)
        let folder = RemoteFileItem(name: "dir", path: "/dir", kind: .directory)
        var viewed: [RemoteFileItem] = []
        var edited = false
        coordinator.onViewFile = { viewed.append($0) }
        coordinator.onOpenFile = { _ in edited = true }
        #expect(!coordinator.viewFile(selection: []))
        #expect(!coordinator.viewFile(selection: [folder]))
        #expect(!coordinator.viewFile(selection: [file, folder]))
        #expect(coordinator.viewFile(selection: [file]))
        #expect(viewed == [file])
        #expect(!edited)
    }

    @Test func aRealF3EventOpensTheSelectedFileWithoutEditingIt() throws {
        let file = RemoteFileItem(name: "fixture.txt", path: "/fixture.txt", kind: .file)
        var viewed: [RemoteFileItem] = []
        var edited = false
        let view = RemoteFileTableView(items: [file], selectedPaths: [file.path],
            onOpen: { _ in }, onSelect: { _ in }, onOpenFile: { _ in edited = true },
            onViewFile: { viewed.append($0) }, side: .remote)
        let root = NSHostingView(rootView: view)
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        root.layoutSubtreeIfNeeded()
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let table = try #require(tables(in: root).first)
        #expect(table.numberOfRows == 1)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 99))
        table.keyDown(with: event)
        #expect(viewed == [file])
        #expect(!edited)
    }

    @Test func nativeTextSurfaceHasUsableGeometryAndPlainMonospacedStorage() throws {
        let root = NSHostingView(rootView: FileToolTextView(text: .constant("first\nsecond"), editable: true))
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        root.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let text = try #require(textViews(in: root).first)
        #expect(text.string == "first\nsecond")
        #expect(text.frame.width > 0)
        #expect(text.frame.height > 0)
        #expect(text.isEditable)
        #expect(!text.isRichText)
        #expect(text.layoutManager?.allowsNonContiguousLayout == true)
    }

    private func fixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-" + UUID().uuidString)
        try data.write(to: url)
        return url
    }

    @Test func editorPreservesUTF8BOMAndLineEndingsOnSave() async throws {
        let url = try fixture(Data([0xEF, 0xBB, 0xBF]) + Data("hello\r\nworld\r\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: true)
        await model.open()
        #expect(model.ready)
        #expect(model.text == "hello\r\nworld\r\n")
        #expect(!model.dirty)
        model.text += "é\r\n"
        #expect(model.dirty)
        await model.save()
        #expect(model.errorMessage == nil)
        #expect(!model.dirty)
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data(model.text.utf8))
        await model.close()
        #expect(!model.ready)
    }

    @Test func binaryContentCannotBeOverwrittenByTheTextEditor() async throws {
        let original = Data([0, 255, 1, 2])
        let url = try fixture(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let editor = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: true)
        await editor.open()
        #expect(!editor.ready)
        #expect(editor.errorMessage != nil)
        editor.text = "replacement"
        await editor.save()
        #expect(try Data(contentsOf: url) == original)
        await editor.close()
        let viewer = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: false)
        await viewer.open()
        #expect(viewer.ready)
        #expect(viewer.hexadecimal)
        #expect(viewer.data == original)
        await viewer.close()
    }

    @Test func viewerRetainsOnlyOneWindowAndSearchJumpsAcrossWindows() async throws {
        var bytes = Data(repeating: 65, count: FileWindow.size - 2)
        bytes.append(Data("needle".utf8))
        bytes.append(Data(repeating: 66, count: FileWindow.size))
        let url = try fixture(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: false)
        await model.open()
        #expect(model.data.count == FileWindow.size)
        #expect(model.size == UInt64(bytes.count))
        model.query = "needle"
        model.findNext()
        let search = try #require(model.searchTask)
        await search.value
        #expect(model.offset == UInt64(FileWindow.size - 2))
        #expect(model.data.starts(with: Data("needle".utf8)))
        #expect(model.data.count == FileWindow.size)
        model.findNext()
        await model.searchTask?.value
        #expect(model.offset == UInt64(FileWindow.size - 2))
        #expect(model.searchStatus == L10n.string("filetools.searchWrapped", "wrapped"))
        await model.close()
    }

    @Test func previousAndNextNavigateOccurrencesWithoutACountOrAnOffsetField() async throws {
        let url = try fixture(Data("é x é x é".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: false)
        await model.open()
        model.query = "é"
        model.findNext(); await model.searchTask?.value
        #expect(model.offset == 0)
        #expect(model.selectedRanges == [NSRange(location: 0, length: 1)])
        model.findNext(); await model.searchTask?.value
        #expect(model.offset == 5)
        model.findPrevious(); await model.searchTask?.value
        #expect(model.offset == 0)
        model.findPrevious(); await model.searchTask?.value
        #expect(model.offset == 10)
        #expect(model.searchStatus == L10n.string("filetools.searchWrapped", "wrapped"))
        model.hexadecimal = true
        #expect(model.selectedRanges == [NSRange(location: 18, length: 5)])
        model.query = "absent"
        #expect(model.selectedRanges.isEmpty)
        model.findNext(); await model.searchTask?.value
        #expect(model.searchStatus == L10n.string("filetools.notFound", "missing"))
        await model.close()
    }

    @Test func aSingleDebianMarkerInABinaryArchiveStaysFindableInBothDirections() async throws {
        let url = try fixture(Data("!<arch>\ndebian-binary   ".utf8) + Data([0, 255, 1, 0]))
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: false)
        await model.open()
        #expect(model.hexadecimal)
        model.query = "debian"
        model.findNext(); await model.searchTask?.value
        #expect(model.offset == 8)
        #expect(model.searchStatus == L10n.string("filetools.matchFound", "found"))
        #expect(model.selectedRanges == [NSRange(location: 18, length: 17)])
        for forward in [true, true, false, false] {
            if forward { model.findNext() } else { model.findPrevious() }
            await model.searchTask?.value
            #expect(model.offset == 8)
            #expect(model.data.starts(with: Data("debian".utf8)))
            #expect(model.searchStatus == L10n.string("filetools.searchWrapped", "wrapped"))
        }
        model.query = "missing"
        model.findNext(); await model.searchTask?.value
        #expect(model.searchStatus == L10n.string("filetools.notFound", "missing"))
        #expect(model.selectedRanges.isEmpty)
        await model.close()
    }

    @Test func changedFilesAreNotOverwritten() async throws {
        let url = try fixture(Data("original".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: true)
        await model.open()
        model.text = "edited"
        let replacement = Data("external replacement".utf8)
        try replacement.write(to: url)
        await model.save()
        #expect(model.errorMessage != nil)
        #expect(model.dirty)
        #expect(try Data(contentsOf: url) == replacement)
        await model.close()
    }

    @Test func oversizedFilesRemainViewableButNotEditable() async throws {
        let url = try fixture(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(FileTextCodec.maximumBytes + 1))
        try writer.close()
        let model = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: true)
        await model.open()
        #expect(!model.ready)
        #expect(model.errorMessage != nil)
        await model.close()
        let viewer = FileInspectionModel(source: LocalFileSystem(), path: url.path, editing: false)
        await viewer.open()
        #expect(viewer.ready)
        #expect(viewer.data.count == FileWindow.size)
        await viewer.close()
    }
}
