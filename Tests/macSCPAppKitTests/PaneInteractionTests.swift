import AppKit
import Testing
import macSCPCore
@testable import MacSCPAppKit

@Suite("Commander pane interactions")
@MainActor
struct PaneInteractionTests {
    @Test func metadataChangesReloadOnlyTheirRowsAndAccountForTheParentRow() {
        let a = RemoteFileItem(name: "a", path: "/a", kind: .file)
        let b = RemoteFileItem(name: "b", path: "/b", kind: .file)
        let filled = RemoteFileItem(name: "b", path: "/b", kind: .file, modifiedAt: Date())
        #expect(RemoteFileTableView.metadataRowsToReload(old: [a, b], new: [a, filled], parentRow: false) == IndexSet(integer: 1))
        #expect(RemoteFileTableView.metadataRowsToReload(old: [a, b], new: [a, filled], parentRow: true) == IndexSet(integer: 2))
        #expect(RemoteFileTableView.metadataRowsToReload(old: [a, b], new: [a, b], parentRow: true) == IndexSet())
        #expect(RemoteFileTableView.metadataRowsToReload(old: [a, b], new: [b, a], parentRow: false) == nil)
        #expect(RemoteFileTableView.metadataRowsToReload(old: [a], new: [a, b], parentRow: false) == nil)
    }
    @Test func parentRowHasOneNativeNavigationSymbolAndReadableLabel() throws {
        let source = coordinator(.local, group: UUID())
        source.showsParentRow = true
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init(FileColumn.name.rawValue))
        let cell = try #require(source.tableView(table, viewFor: column, row: 0) as? NSTableCellView)
        let icon = try #require(cell.imageView)
        let image = try #require(icon.image)
        #expect(image.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) != nil)
        #expect(!icon.isHidden)
        #expect(icon.frame.width > 0)
        #expect(cell.textField?.stringValue == "..")
        #expect(cell.textField?.font != nil)
        let arrows = cell.subviews.compactMap { $0 as? NSImageView }.filter { $0 !== icon }
        #expect(arrows.isEmpty)
    }
    private let file = RemoteFileItem(name: "note.txt", path: "/note.txt", kind: .file)
    private let folder = RemoteFileItem(name: "docs", path: "/docs", kind: .directory)

    private func coordinator(_ side: BrowserPaneSide, group: UUID) -> RemoteFileTableView.Coordinator {
        let result = RemoteFileTableView.Coordinator(onOpen: { _ in }, onSelect: { _ in }, side: side)
        result.transferGroupID = group
        result.items = [file, folder]
        return result
    }

    @Test func parentRowNeverBecomesAFileOrDragSource() {
        let source = coordinator(.local, group: UUID())
        source.showsParentRow = true
        let table = NSTableView()
        #expect(source.numberOfRows(in: table) == 3)
        #expect(source.item(at: 0) == nil)
        #expect(source.item(at: -1) == nil)
        #expect(source.item(at: 1) == file)
        #expect(source.item(at: 2) == folder)
        #expect(source.item(at: 3) == nil)
        #expect(source.tableView(table, pasteboardWriterForRow: 0) == nil)
        #expect(source.tableView(table, pasteboardWriterForRow: 2) != nil)
        var parentOpens = 0
        var openedItems: [RemoteFileItem] = []
        source.onGoUp = { parentOpens += 1 }
        source.onOpen = { openedItems.append($0) }
        source.openRow(0)
        #expect(parentOpens == 1)
        #expect(openedItems.isEmpty)
        source.openRow(2)
        #expect(openedItems == [folder])
        source.showsParentRow = false
        #expect(source.numberOfRows(in: table) == 2)
        #expect(source.item(at: 0) == file)
    }

    @Test(arguments: [BrowserPaneSide.local, .remote])
    func dropUsesTheFrozenMultiSelectionAndExistingTransferAction(side: BrowserPaneSide) async {
        let group = UUID()
        let source = coordinator(side, group: group)
        let target = coordinator(side == .local ? .remote : .local, group: group)
        var delivered: [RemoteFileItem] = []
        source.onMenuAction = { entry, selection in
            #expect(entry == .transferToOtherPane)
            delivered = selection
        }
        source.beginPaneDrag(rows: IndexSet([0, 1]))
        #expect(target.canReceiveDrag(from: source))
        #expect(target.receiveDrag(from: source))
        #expect(delivered.isEmpty)
        await target.dropPublicationTask?.value
        #expect(delivered == [file, folder])
        #expect(!target.receiveDrag(from: source))
        source.endPaneDrag()
        #expect(!target.receiveDrag(from: source))
    }

    @Test func dropRejectsOtherConnectionsSamePaneAndStaleSource() {
        let group = UUID()
        let source = coordinator(.local, group: group)
        let target = coordinator(.remote, group: group)
        source.beginPaneDrag(rows: IndexSet(integer: 0))
        #expect(!source.canReceiveDrag(from: source))
        #expect(!coordinator(.local, group: group).canReceiveDrag(from: source))
        #expect(!coordinator(.remote, group: UUID()).canReceiveDrag(from: source))
        source.directoryPath = "/elsewhere"
        #expect(!target.receiveDrag(from: source))
        source.directoryPath = "/"
        source.items = []
        #expect(!target.receiveDrag(from: source))
    }

    @Test func dropPreservesScopeAndLoadingGates() {
        let group = UUID()
        let source = coordinator(.local, group: group)
        let target = coordinator(.remote, group: group)
        source.beginPaneDrag(rows: IndexSet(integer: 0))
        #expect(target.canReceiveDrag(from: source))
        target.scope = BrowserScope(rootIsContainerList: true, currentPath: "/")
        #expect(!target.receiveDrag(from: source))
        target.scope = .ordinary
        target.transfersEnabled = false
        #expect(!target.receiveDrag(from: source))
        target.transfersEnabled = true
        source.transfersEnabled = false
        #expect(!target.receiveDrag(from: source))
    }

    @Test func iconsUseListingMetadataWithoutFilesystemAccess() {
        #expect(RemoteFileTableView.iconSymbol(for: folder) == "folder")
        #expect(RemoteFileTableView.iconSymbol(for: file) == "doc")
        let executable = RemoteFileItem(name: "tool", path: "/tool", kind: .file, permissions: 0o755)
        #expect(RemoteFileTableView.iconSymbol(for: executable) == "terminal")
        let hidden = RemoteFileItem(name: ".config", path: "/.config", kind: .file)
        #expect(RemoteFileTableView.iconSymbol(for: hidden) == "doc")
    }

    @Test func metadataEnrichmentDoesNotInvalidateAnActiveDrag() {
        let group = UUID()
        let source = coordinator(.local, group: group)
        let target = coordinator(.remote, group: group)
        source.beginPaneDrag(rows: IndexSet(integer: 0))
        source.items[0] = RemoteFileItem(name: file.name, path: file.path, kind: .file,
            size: 42, permissions: 0o644)
        #expect(target.canReceiveDrag(from: source))
        source.transferGroupID = UUID()
        #expect(!target.receiveDrag(from: source))
    }

    @Test func finderDropsStillReadOnlyFileURLsAndRespectDestinationGates() {
        let target = coordinator(.remote, group: UUID())
        #expect(!target.acceptsFileURLs)
        target.onDropURLs = { _ in }
        #expect(target.acceptsFileURLs)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let fileURL = URL(fileURLWithPath: "/tmp/macscp-drag-fixture")
        pasteboard.writeObjects([fileURL as NSURL])
        #expect(RemoteFileTableView.Coordinator.fileURLs(from: pasteboard) == [fileURL])
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(string: "https://example.invalid/file")!])
        #expect(RemoteFileTableView.Coordinator.fileURLs(from: pasteboard).isEmpty)
        target.scope = BrowserScope(rootIsContainerList: true, currentPath: "/")
        #expect(!target.acceptsFileURLs)
        target.scope = .ordinary
        target.transfersEnabled = false
        #expect(!target.acceptsFileURLs)
    }
}
