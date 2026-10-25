import AppKit
import Testing
import macSCPCore
@testable import MacSCPAppKit

@MainActor
@Suite("Table delegate publication")
struct TableDelegatePublicationTests {
    @Test func fileDropsLeaveTheDelegateStackAndPreserveAcceptanceOrder() async {
        let (_, coordinator) = fixture()
        let first = URL(fileURLWithPath: "/tmp/first-drop")
        let second = URL(fileURLWithPath: "/tmp/second-drop")
        var deliveries: [[URL]] = []
        coordinator.onDropURLs = { deliveries.append($0) }
        #expect(coordinator.receiveFileURLs([first]))
        #expect(coordinator.receiveFileURLs([second]))
        #expect(deliveries.isEmpty)
        await coordinator.dropPublicationTask?.value
        #expect(deliveries == [[first], [second]])
    }

    @Test func aDropCannotLandInADirectoryChangedBeforePublication() async {
        let (_, coordinator) = fixture()
        var delivered = false
        coordinator.onDropURLs = { _ in delivered = true }
        #expect(coordinator.receiveFileURLs([URL(fileURLWithPath: "/tmp/drop")]))
        #expect(!delivered)
        coordinator.directoryPath = "/another-directory"
        await coordinator.dropPublicationTask?.value
        #expect(!delivered)
    }

    private let items = [
        RemoteFileItem(name: "a", path: "/a", kind: .file),
        RemoteFileItem(name: "b", path: "/b", kind: .file),
    ]

    private func fixture() -> (NSTableView, RemoteFileTableView.Coordinator) {
        let coordinator = RemoteFileTableView.Coordinator(onOpen: { _ in }, onSelect: { _ in }, side: .remote)
        coordinator.items = items
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init(FileColumn.name.rawValue)))
        table.dataSource = coordinator
        coordinator.table = table
        table.reloadData()
        return (table, coordinator)
    }

    @Test func selectionLeavesTheDelegateStackAndCoalescesRapidChanges() async {
        let (table, coordinator) = fixture()
        var delivered: [[RemoteFileItem]] = []
        coordinator.onSelect = { delivered.append($0) }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(delivered.isEmpty)
        await coordinator.selectionPublicationTask?.value
        #expect(delivered == [[items[1]]])
    }

    @Test func anOldSelectionCannotLandAfterDirectoryReplacement() async {
        let (table, coordinator) = fixture()
        var delivered: [[RemoteFileItem]] = []
        coordinator.onSelect = { delivered.append($0) }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        coordinator.items = [RemoteFileItem(name: "other", path: "/other", kind: .file)]
        #expect(delivered.isEmpty)
        await coordinator.selectionPublicationTask?.value
        #expect(delivered.isEmpty)
    }

    @Test func sortLeavesTheDelegateStackAndDoesNotEchoReconciledState() async {
        let (table, coordinator) = fixture()
        var delivered: [FileSortKey] = []
        coordinator.onSortChange = { key, _ in delivered.append(key) }
        table.sortDescriptors = [NSSortDescriptor(key: FileColumn.name.rawValue, ascending: false)]
        coordinator.tableView(table, sortDescriptorsDidChange: [])
        coordinator.tableView(table, sortDescriptorsDidChange: [])
        #expect(delivered.isEmpty)
        await coordinator.sortPublicationTask?.value
        #expect(delivered == [.name])
    }
}
