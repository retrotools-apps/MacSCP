import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

struct TransferQueueViewportTests {
    private func item(_ status: TransferQueueViewModel.Item.Status) -> TransferQueueViewModel.Item {
        .init(id: UUID(), fileName: "fixture.bin", direction: .upload, status: status,
              sourcePath: "/source/fixture.bin", destinationTabID: nil, isEditUpload: false,
              destinationDirectory: "/destination", destinationPath: "/destination/fixture.bin",
              destinationSupportsResume: true, crossRemote: false, crossBackendTarget: nil)
    }

    @Test(arguments: [CGFloat(24), CGFloat(42)])
    func viewportGrowsOnlyToTwoRows(rowHeight: CGFloat) {
        #expect(TransferQueueViewport.height(itemCount: 1, rowHeight: rowHeight) == rowHeight + 8)
        #expect(TransferQueueViewport.height(itemCount: 2, rowHeight: rowHeight) == rowHeight * 2 + 10)
        #expect(TransferQueueViewport.height(itemCount: 100, rowHeight: rowHeight)
            == TransferQueueViewport.height(itemCount: 2, rowHeight: rowHeight))
    }

    @Test func followsRunningWorkPastFinishedRowsAndAdvancesWhenItFinishes() {
        let completed = item(.finished)
        let queued = item(.queued)
        let active = item(.running(.init(bytesTransferred: 1, totalBytes: 100)))
        let next = item(.running(.init(bytesTransferred: 2, totalBytes: 100)))
        #expect(TransferQueueViewport.activeTarget(in: [completed, queued, active, next]) == active.id)
        var finished = active
        finished.status = .finished
        #expect(TransferQueueViewport.activeTarget(in: [completed, queued, finished, next]) == next.id)
        #expect(TransferQueueViewport.activeTarget(in: [completed, queued, finished]) == queued.id)
        #expect(TransferQueueViewport.activeTarget(in: [completed, finished]) == nil)
    }

    @Test func progressUpdatesKeepTheSameScrollTarget() {
        var active = item(.running(.init(bytesTransferred: 1, totalBytes: 100)))
        let original = TransferQueueViewport.activeTarget(in: [item(.finished), active])
        active.status = .running(.init(bytesTransferred: 50, totalBytes: 100))
        #expect(TransferQueueViewport.activeTarget(in: [item(.finished), active]) == original)
    }
}
