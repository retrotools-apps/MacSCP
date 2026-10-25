import Foundation

public enum FileToolError: Error, Sendable, Equatable {
    case unsupported
    case invalidRange
    case oversizedResponse
    case closed
    case invalidQuery
    case textOnly
    case editorSizeLimit
    case commandFailed(Int)
    case resultsTooLarge
    case changed
    case searchUnavailable
}

/// A pull-only random-access reader. No method downloads a complete file.
public protocol ByteWindowReader: Sendable {
    func read(offset: UInt64, count: Int) async throws -> Data
    func close() async
}

/// Separate from transfer streams so unsupported backends cannot silently
/// download a large file just to display one page.
public protocol WindowedFileAccess: RemoteFileSystem {
    func openWindowedFile(path: String) async throws -> any ByteWindowReader
}

public enum FileWindow {
    public static let size = 64 * 1024
    public static let maximumQueryBytes = 4096

    public static func validate(offset: UInt64, count: Int) throws {
        guard count >= 0, count <= size, UInt64(count) <= UInt64.max - offset else {
            throw FileToolError.invalidRange
        }
    }

    /// Streaming literal-byte search, including matches spanning windows.
    /// Memory is bounded by one window plus the query, independent of file size.
    public static func find(
        _ needle: Data, in reader: any ByteWindowReader, from start: UInt64,
        to end: UInt64, progress: @Sendable (UInt64) async -> Void = { _ in }
    ) async throws -> UInt64? {
        guard !needle.isEmpty, needle.count <= maximumQueryBytes else { throw FileToolError.invalidQuery }
        guard start <= end else { throw FileToolError.invalidRange }
        var offset = start
        var tail = Data()
        while offset < end {
            try Task.checkCancellation()
            let count = Int(min(UInt64(size), end - offset))
            let next = try await reader.read(offset: offset, count: count)
            guard next.count <= count else { throw FileToolError.oversizedResponse }
            if next.isEmpty { return nil }
            var buffer = tail
            buffer.append(next)
            if let match = buffer.range(of: needle) {
                return offset - UInt64(tail.count) + UInt64(buffer.distance(from: buffer.startIndex, to: match.lowerBound))
            }
            offset += UInt64(next.count)
            tail = Data(buffer.suffix(needle.count - 1))
            await progress(offset)
        }
        return nil
    }

    public static func isBinary(_ data: Data, allowingIncompleteUTF8Suffix: Bool = false) -> Bool {
        if data.contains(0) { return true }
        if String(data: data, encoding: .utf8) != nil { return false }
        if allowingIncompleteUTF8Suffix {
            // A window can end inside a UTF-8 scalar. Appending continuation
            // bytes can repair that suffix, but cannot repair malformed bytes
            // earlier in the window. These fills cover the E0/F0 lower bounds.
            for missing in 1...3 {
                for fill in [UInt8(0x80), 0x90, 0xA0] {
                    if String(data: data + Data(repeating: fill, count: missing), encoding: .utf8) != nil { return false }
                }
            }
        }
        return true
    }

    public static func hex(_ data: Data, offset: UInt64) -> String {
        stride(from: 0, to: data.count, by: 16).map { start in
            let bytes = Array(data.dropFirst(start).prefix(16))
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%016llX  ", offset + UInt64(start))
                + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
}

/// The editor intentionally stays bounded; huge files belong in the viewer.
/// Invalid UTF-8 and binary content are never decoded lossily and saved back.
public enum FileTextCodec {
    public static let maximumBytes = 8 * 1024 * 1024
    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw FileToolError.editorSizeLimit }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw FileToolError.textOnly
        }
        return text
    }
    public static func stream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
        let cursor = FileEditCursor(data: data)
        return AsyncThrowingStream(unfolding: { try Task.checkCancellation(); return await cursor.next() })
    }
}

private actor FileEditCursor {
    let data: Data
    var offset = 0
    init(data: Data) { self.data = data }
    func next() -> Data? {
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + FileWindow.size)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}
