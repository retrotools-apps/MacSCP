import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

@MainActor
@Suite("Destination-scoped transfer cancellation", .timeLimit(.minutes(1)))
struct TransferDestinationCancellationTests {
    typealias Signal = TransferQueueViewModelTests.TestSignal
    typealias FileSystem = TransferQueueViewModelTests.QueueTestFS

    @Test func cancellingOneDestinationSettlesItsRunningAndQueuedJobsOnly() async throws {
        let firstStarted = Signal(), secondStarted = Signal(), firstGate = Signal(), secondGate = Signal()
        let source = FileSystem(reads: [
            "/first": .init(content: Data([1]), started: firstStarted, gate: firstGate),
            "/second": .init(content: Data([2]), started: secondStarted, gate: secondGate),
            "/queued": .init(content: Data([3]))
        ])
        let destination = FileSystem(reads: [:])
        let queue = TransferQueueViewModel()
        queue.maxConcurrent = 2
        let closing = UUID(), survivor = UUID()
        for (name, target) in [("first", closing), ("second", survivor), ("queued", closing)] {
            queue.enqueue(fileName: name, direction: .upload, source: source, sourcePath: "/" + name,
                destination: destination, destinationDirectory: "/out", onCompleted: nil,
                destinationTabID: target, crossRemote: true)
        }
        try await firstStarted.wait()
        try await secondStarted.wait()
        await queue.cancelTransfers(to: closing)
        #expect(queue.items.filter { $0.destinationTabID == closing }.allSatisfy { $0.status == .cancelled })
        #expect(queue.items.first { $0.destinationTabID == survivor }?.status.isRunning == true)
        #expect(!queue.hasActiveItems(destinationTabID: closing))
        secondGate.fire()
        try await pollUntil("surviving destination finishes") { !queue.isActive }
        #expect(queue.items.first { $0.destinationTabID == survivor }?.status == .finished)
        #expect(await destination.writtenData(at: "/out/second") == Data([2]))
        #expect(await destination.writtenData(at: "/out/queued") == nil)
    }

    @Test func aTreeCanBeCancelledBeforeItsFirstFileIsEnqueued() async throws {
        let entered = Signal(), gate = Signal()
        let source = FileSystem(reads: [:], listings: ["/folder": []], listEntered: entered, listGate: gate)
        let destination = FileSystem(reads: [:])
        let queue = TransferQueueViewModel()
        let target = UUID()
        queue.enqueueTree(directoryName: "folder", direction: .upload, source: source,
            sourceDirectory: "/folder", destination: destination, destinationDirectory: "/out",
            onCompleted: { Issue.record("A fully cancelled expansion must not report completion") },
            destinationTabID: target, crossRemote: true)
        try await entered.wait()
        #expect(queue.items.isEmpty)
        #expect(queue.hasActiveItems(destinationTabID: target))
        await queue.cancelTransfers(to: target)
        #expect(!queue.hasActiveItems(destinationTabID: target))
        #expect(queue.items.isEmpty)
    }

    @Test func anOpenDestinationConflictIsDismissedBeforeWaitingForItsWorker() async throws {
        let source = FileSystem(reads: ["/file": .init(content: Data([1]))])
        let destination = FileSystem(reads: ["/out/file": .init(content: Data([2]))],
            preWritten: ["/out/file": Data([2])])
        let queue = TransferQueueViewModel()
        let bridge = ConflictPromptBridge()
        let entered = Signal()
        queue.conflictDecider = { conflict in
            entered.fire()
            return await bridge.ask(conflict)
        }
        let target = UUID()
        queue.enqueue(fileName: "file", direction: .upload, source: source, sourcePath: "/file",
            destination: destination, destinationDirectory: "/out", onCompleted: nil,
            destinationTabID: target, crossRemote: true)
        try await entered.wait()
        #expect(bridge.currentPrompt != nil)
        var cancellations = 0
        await queue.cancelTransfers(to: target, cancelConflict: {
            cancellations += 1
            bridge.cancelOpenPrompt()
        })
        #expect(cancellations == 1)
        #expect(bridge.currentPrompt == nil)
        #expect(queue.items.first?.status == .cancelled)
        #expect(await destination.writtenData(at: "/out/file") == Data([2]))
    }
}
