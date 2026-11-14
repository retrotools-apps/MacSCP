import Foundation
import Testing
@testable import macSCPCore

@Suite(.timeLimit(.minutes(1)))
struct SFTPTransferPipelineTests {
    actor Peer {
        var active = 0
        var peak = 0
        var calls = 0
        var held = false
        func hold() { held = true }
        func release() { held = false }
        var data: Data
        let barrier: Int
        init(data: Data = Data(), barrier: Int = SFTPTransferPipeline.depth) {
            self.data = data
            self.barrier = barrier
        }
        func enter() async {
            active += 1
            calls += 1
            peak = max(peak, active)
            while calls < barrier || held { await Task.yield() }
        }
        func read(_ offset: UInt64, _ length: Int) async -> Data {
            await enter()
            defer { active -= 1 }
            let start = min(Int(offset), data.count)
            // Force short replies to verify that every range is filled.
            return data.subdata(in: start..<min(start + min(length, 8191), data.count))
        }
        func write(_ bytes: Data, _ offset: UInt64) async {
            await enter()
            defer { active -= 1 }
            let start = Int(offset)
            if data.count < start + bytes.count { data.count = start + bytes.count }
            data.replaceSubrange(start..<start + bytes.count, with: bytes)
        }
    }

    @Test func readsAreConcurrentBoundedAndOrderedAcrossShortRepliesAndEOF() async throws {
        let bytes = Data((0..<(SFTPTransferPipeline.requestBytes * 3 + 137)).map { UInt8($0 % 251) })
        let peer = Peer(data: bytes)
        let result = try await SFTPTransferPipeline.readBatch(from: 17) { await peer.read($0, $1) }
        #expect(result == bytes.dropFirst(17))
        #expect(await peer.peak == SFTPTransferPipeline.depth)
        #expect(await peer.active == 0)
    }

    @Test func pipelinedWritesPreserveOffsetsAndResumePrefix() async throws {
        let prefix = Data(repeating: 99, count: 137)
        let bytes = Data((0..<(SFTPTransferPipeline.requestBytes * 70 + 11)).map { UInt8($0 % 251) })
        let peer = Peer(data: prefix)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(bytes.prefix(65536))
            continuation.yield(bytes.dropFirst(65536))
            continuation.finish()
        }
        try await SFTPTransferPipeline.write(contents: stream, from: UInt64(prefix.count)) {
            await peer.write($0, $1)
        }
        #expect(await peer.data == prefix + bytes)
        #expect(await peer.peak == SFTPTransferPipeline.depth)
        #expect(await peer.active == 0)
    }

    @Test func readErrorDrainsRequestsBeforeReturning() async {
        let peer = Peer()
        do {
            _ = try await SFTPTransferPipeline.readBatch(from: 0) { offset, count in
                let bytes = await peer.read(offset, count)
                if offset == 0 { throw RemoteFSError.permissionDenied(path: "/fixture") }
                return bytes
            }
            Issue.record("Expected read failure")
        } catch {
            #expect(error is RemoteFSError)
        }
        #expect(await peer.active == 0)
    }

    @Test func cancellationDrainsTheReadBatchWithoutIssuingMoreRequests() async {
        let peer = Peer(data: Data(repeating: 1, count: SFTPTransferPipeline.requestBytes * 65))
        await peer.hold()
        let task = Task {
            try await SFTPTransferPipeline.readBatch(from: 0) { await peer.read($0, $1) }
        }
        while await peer.calls < SFTPTransferPipeline.depth { await Task.yield() }
        #expect(await peer.active == SFTPTransferPipeline.depth)
        task.cancel()
        await peer.release()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(await peer.calls == SFTPTransferPipeline.depth)
        #expect(await peer.active == 0)
    }

    @Test func writeFailureDrainsAllStartedRequests() async {
        let peer = Peer()
        let stream = AsyncThrowingStream<Data, Error> {
            $0.yield(Data(repeating: 1, count: SFTPTransferPipeline.requestBytes * 70)); $0.finish()
        }
        do {
            try await SFTPTransferPipeline.write(contents: stream, from: 0) { bytes, offset in
                await peer.write(bytes, offset)
                if offset == 0 { throw RemoteFSError.permissionDenied(path: "/fixture") }
            }
            Issue.record("Expected write failure")
        } catch { #expect(error is RemoteFSError) }
        #expect(await peer.active == 0)
        #expect(await peer.peak <= SFTPTransferPipeline.depth)
    }

    @Test func cancelledWriteDoesNotIssueRequests() async {
        let peer = Peer(barrier: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let stream = AsyncThrowingStream<Data, Error> { $0.yield(Data([1])); $0.finish() }
            try await SFTPTransferPipeline.write(contents: stream, from: 0) { await peer.write($0, $1) }
        }
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(await peer.calls == 0)
    }
}
