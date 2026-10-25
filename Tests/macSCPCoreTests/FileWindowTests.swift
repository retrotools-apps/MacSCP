import Foundation
import Testing
@testable import macSCPCore

@Suite("Bounded file windows")
struct FileWindowTests {
    @Test func reverseSearchFindsAMatchAcrossTheReverseWindowBoundary() async throws {
        var bytes = Data(repeating: 65, count: FileWindow.size * 2)
        bytes.replaceSubrange((FileWindow.size - 2)..<(FileWindow.size + 4), with: Data("needle".utf8))
        let reader = Reader(bytes)
        #expect(try await FileWindow.findPrevious(Data("needle".utf8), in: reader, from: 0, to: UInt64(bytes.count)) == UInt64(FileWindow.size - 2))
        let requests = await reader.requests
        #expect(requests.count == 2)
        #expect(requests.first?.0 == UInt64(FileWindow.size))
        #expect(requests.allSatisfy { $0.1 <= FileWindow.size })
    }

    @Test func reverseSearchHandlesShortReadsAnd64BitOffsets() async throws {
        let base: UInt64 = 400 * 1024 * 1024 * 1024
        let reader = Reader(Data("a-needle-b-needle".utf8), base: base, shortRead: 2)
        let found = try await FileWindow.findPrevious(Data("needle".utf8), in: reader, from: base, to: base + 17)
        #expect(found == base + 11)
        let requests = await reader.requests
        #expect(requests.allSatisfy { $0.0 >= base && $0.1 <= FileWindow.size })
    }

    private actor Reader: ByteWindowReader {
        let data: Data
        let base: UInt64
        let shortRead: Int
        var requests: [(UInt64, Int)] = []
        init(_ data: Data, base: UInt64 = 0, shortRead: Int = FileWindow.size) {
            self.data = data; self.base = base; self.shortRead = shortRead
        }
        func read(offset: UInt64, count: Int) async throws -> Data {
            requests.append((offset, count))
            guard offset >= base, offset - base < UInt64(data.count) else { return Data() }
            let start = Int(offset - base)
            return data.subdata(in: start..<min(data.count, start + min(shortRead, count)))
        }
        func close() async {}
    }

    @Test func searchFindsAMatchAcrossAWindowBoundary() async throws {
        var bytes = Data(repeating: 65, count: FileWindow.size - 2)
        bytes.append(Data("needle-tail".utf8))
        let reader = Reader(bytes)
        let found = try await FileWindow.find(Data("needle".utf8), in: reader, from: 0, to: UInt64(bytes.count))
        #expect(found == UInt64(FileWindow.size - 2))
        let requests = await reader.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.1 <= FileWindow.size })
    }

    @Test func searchHandlesShortReadsAndOffsetsBeyond32Bits() async throws {
        let base: UInt64 = 400 * 1024 * 1024 * 1024
        let reader = Reader(Data("a-needle-b".utf8), base: base, shortRead: 2)
        #expect(try await FileWindow.find(Data("needle".utf8), in: reader, from: base, to: base + 10) == base + 2)
        let requests = await reader.requests
        #expect(requests.first?.0 == base)
        #expect(requests.count > 2)
    }

    @Test func eofStopsSearchEvenWhenTheAdvertisedSizeIsStale() async throws {
        let reader = Reader(Data("abc".utf8))
        #expect(try await FileWindow.find(Data("missing".utf8), in: reader, from: 0, to: UInt64.max) == nil)
        #expect(await reader.requests.count == 2)
    }

    @Test func searchNeverReturnsAMatchBeyondTheRequestedEnd() async throws {
        let reader = Reader(Data("ab-needle".utf8))
        #expect(try await FileWindow.find(Data("needle".utf8), in: reader, from: 0, to: 6) == nil)
    }

    @Test func cancelledSearchDoesNotRead() async throws {
        let reader = Reader(Data("abc".utf8))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileWindow.find(Data("a".utf8), in: reader, from: 0, to: 3)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await reader.requests.isEmpty)
    }

    @Test func rangeValidationRejectsOverflowAndOversizedWindows() throws {
        #expect(throws: FileToolError.invalidRange) { try FileWindow.validate(offset: UInt64.max, count: 1) }
        #expect(throws: FileToolError.invalidRange) { try FileWindow.validate(offset: 0, count: FileWindow.size + 1) }
        #expect(throws: FileToolError.invalidRange) { try FileWindow.validate(offset: 0, count: -1) }
        try FileWindow.validate(offset: UInt64.max, count: 0)
    }

    @Test func emptyAndOversizedQueriesAreRejected() async throws {
        let reader = Reader(Data())
        for query in [Data(), Data(repeating: 65, count: FileWindow.maximumQueryBytes + 1)] {
            await #expect(throws: FileToolError.invalidQuery) {
                try await FileWindow.find(query, in: reader, from: 0, to: 1)
            }
        }
        #expect(await reader.requests.isEmpty)
    }

    @Test func localReaderSeeksIntoASparse400GiBFileWithoutReadingItsPrefix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("window-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        let offset: UInt64 = 400 * 1024 * 1024 * 1024
        try writer.seek(toOffset: offset)
        try writer.write(contentsOf: Data("tail".utf8))
        try writer.close()
        let reader = try await LocalFileSystem().openWindowedFile(path: url.path)
        #expect(try await reader.read(offset: offset, count: 4) == Data("tail".utf8))
        #expect(try await reader.read(offset: offset + 4, count: 4).isEmpty)
        await reader.close()
        await #expect(throws: FileToolError.closed) { try await reader.read(offset: 0, count: 1) }
    }

    @Test func binaryDetectionAndHexPreserveBytesAnd64BitAddress() throws {
        let bytes = Data([0, 65, 255])
        #expect(FileWindow.isBinary(bytes))
        #expect(!FileWindow.isBinary(Data("été".utf8)))
        let rendered = FileWindow.hex(bytes, offset: 0x100000000)
        #expect(rendered.hasPrefix("0000000100000000  00 41 FF"))
        #expect(rendered.hasSuffix(".A."))
        #expect(throws: FileToolError.textOnly) { try FileTextCodec.decode(bytes) }
    }

    @Test func aWindowEndingInsideAUTF8ScalarIsNotMisclassifiedAsBinary() {
        for prefix in [Data([0xC3]), Data([0xE2, 0x82]), Data([0xF0]), Data([0xE0])] {
            let bytes = Data("text ".utf8) + prefix
            #expect(!FileWindow.isBinary(bytes, allowingIncompleteUTF8Suffix: true))
            #expect(FileWindow.isBinary(bytes))
        }
        #expect(FileWindow.isBinary(Data([65, 255]), allowingIncompleteUTF8Suffix: true))
        #expect(FileWindow.isBinary(Data([65, 0]), allowingIncompleteUTF8Suffix: true))
    }

    @Test func editorDecodingIsLosslessAndItsWriteStreamIsPullBased() async throws {
        let bytes = Data(String(repeating: "é\r\n", count: 30000).utf8)
        #expect(Data(try FileTextCodec.decode(bytes).utf8) == bytes)
        var output = Data()
        for try await chunk in FileTextCodec.stream(bytes) {
            #expect(chunk.count <= FileWindow.size)
            output.append(chunk)
        }
        #expect(output == bytes)
        #expect(throws: FileToolError.editorSizeLimit) {
            try FileTextCodec.decode(Data(repeating: 65, count: FileTextCodec.maximumBytes + 1))
        }
    }
}
