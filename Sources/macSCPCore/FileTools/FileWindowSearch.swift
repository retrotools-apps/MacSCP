import Foundation

public enum FileSearchDirection: Sendable { case forward, backward }

public struct FileSearchWindow: Sendable, Equatable {
    public let offset: UInt64
    public let size: UInt64
    public let data: Data
    public init(offset: UInt64, size: UInt64, data: Data) {
        self.offset = offset; self.size = size; self.data = data
    }
}

/// A search returns the display window itself. Remote implementations must
/// search on the server, never stream the file through the client to find it.
public protocol FileWindowSearching: Sendable {
    func searchWindow(path: String, query: Data, direction: FileSearchDirection,
                      relativeTo match: UInt64?) async throws -> FileSearchWindow?
}

extension FileWindow {
    /// Searches [start, end) in reverse, retaining at most one window and
    /// query.count - 1 overlapping bytes. Short reads never create gaps.
    public static func findPrevious(_ needle: Data, in reader: any ByteWindowReader,
                                    from start: UInt64, to end: UInt64) async throws -> UInt64? {
        guard !needle.isEmpty, needle.count <= maximumQueryBytes else { throw FileToolError.invalidQuery }
        guard start <= end else { throw FileToolError.invalidRange }
        var cursor = end
        var suffix = Data()
        while cursor > start {
            try Task.checkCancellation()
            let lower = cursor - min(UInt64(size), cursor - start)
            let count = Int(cursor - lower)
            var chunk = Data()
            while chunk.count < count {
                try Task.checkCancellation()
                let part = try await reader.read(offset: lower + UInt64(chunk.count), count: count - chunk.count)
                guard part.count <= count - chunk.count else { throw FileToolError.oversizedResponse }
                if part.isEmpty { break }
                chunk.append(part)
            }
            let buffer = chunk.count == count ? chunk + suffix : chunk
            if let found = buffer.range(of: needle, options: .backwards) {
                return lower + UInt64(buffer.distance(from: buffer.startIndex, to: found.lowerBound))
            }
            suffix = Data(buffer.prefix(needle.count - 1))
            cursor = lower
        }
        return nil
    }
}

extension LocalFileSystem: FileWindowSearching {
    public func searchWindow(path: String, query: Data, direction: FileSearchDirection,
                             relativeTo match: UInt64?) async throws -> FileSearchWindow? {
        guard !query.isEmpty, query.count <= FileWindow.maximumQueryBytes else { throw FileToolError.invalidQuery }
        let item = try await stat(path: path)
        guard item.kind == .file, let size = item.size else { throw FileToolError.unsupported }
        let reader = try await openWindowedFile(path: path)
        do {
            let found: UInt64?
            switch direction {
            case .forward:
                let start = match.map { $0 >= size ? size : $0 + 1 } ?? 0
                found = try await FileWindow.find(query, in: reader, from: start, to: size)
            case .backward:
                let anchor = min(match ?? size, size)
                let end = match == nil ? size : anchor + min(size - anchor, UInt64(query.count - 1))
                found = try await FileWindow.findPrevious(query, in: reader, from: 0, to: end)
            }
            var result: FileSearchWindow?
            if let found {
                let data = try await reader.read(offset: found, count: Int(min(UInt64(FileWindow.size), size - found)))
                guard data.starts(with: query) else { throw FileToolError.changed }
                result = FileSearchWindow(offset: found, size: size, data: data)
            }
            await reader.close()
            return result
        } catch { await reader.close(); throw error }
    }
}

/// The short-lived remote helper uses fixed-size reads, including on binary
/// files without line breaks. Only a matched display window crosses SSH.
struct RemoteFileSearchCommand {
    static let outputLimit = ((FileWindow.size + 2) / 3) * 4 + 1024
    let text: String
    init(path: String, query: Data, direction: FileSearchDirection, relativeTo match: UInt64?, watchesConnection: Bool = false) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !query.isEmpty,
              query.count <= FileWindow.maximumQueryBytes else { throw FileToolError.invalidQuery }
        text = "python3 -c " + PosixQuoting.singleQuoted(Self.script) + " "
            + PosixQuoting.singleQuoted(path) + " " + PosixQuoting.singleQuoted(query.base64EncodedString())
            + " " + (direction == .forward ? "forward" : "backward")
            + " " + (match.map(String.init) ?? "none")
            + " " + (watchesConnection ? "watch" : "standalone")
    }

    static func result(_ data: Data) throws -> FileSearchWindow? {
        guard data.count <= outputLimit else { throw FileToolError.oversizedResponse }
        struct Reply: Decodable {
            let status: String
            var offset: String?
            var size: String?
            var window: String?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if reply.status == "missing" { return nil }
        if reply.status == "error" { throw FileToolError.commandFailed(1) }
        guard reply.status == "found", let rawOffset = reply.offset, let offset = UInt64(rawOffset),
              let rawSize = reply.size, let size = UInt64(rawSize), let encoded = reply.window,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= FileWindow.size,
              offset < size, UInt64(bytes.count) <= size - offset else { throw FileToolError.changed }
        return FileSearchWindow(offset: offset, size: size, data: bytes)
    }

    static let script = #"""
import base64, json, os, select, stat, sys
W = 65536
try:
    path, encoded, direction, anchor, watch = sys.argv[1:]
    def check_connection():
        if watch == 'watch' and select.select([0], [], [], 0)[0] and not os.read(0, 1):
            raise ConnectionAbortedError()
    needle = base64.b64decode(encoded, validate=True)
    if not 1 <= len(needle) <= 4096:
        raise ValueError()
    with open(path, 'rb', buffering=0) as f:
        def read_block(count):
            block = bytearray()
            while len(block) < count:
                check_connection()
                part = f.read(count - len(block))
                if not part:
                    break
                block.extend(part)
            return bytes(block)
        info = os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError()
        size = info.st_size
        match = None if anchor == 'none' else min(int(anchor), size)
        found = None
        overlap = b''
        if direction == 'forward':
            cursor = 0 if match is None else min(size, match + 1)
            f.seek(cursor)
            while cursor < size:
                check_connection()
                chunk = f.read(min(W, size - cursor))
                if not chunk:
                    break
                block = overlap + chunk
                index = block.find(needle)
                if index >= 0:
                    found = cursor - len(overlap) + index
                    break
                cursor += len(chunk)
                overlap = block[-(len(needle) - 1):] if len(needle) > 1 else b''
        else:
            cursor = size if match is None else min(size, match + len(needle) - 1)
            while cursor > 0:
                check_connection()
                lower = max(0, cursor - W)
                f.seek(lower)
                chunk = read_block(cursor - lower)
                block = chunk + overlap if len(chunk) == cursor - lower else chunk
                index = block.rfind(needle)
                if index >= 0:
                    found = lower + index
                    break
                overlap = block[:len(needle) - 1]
                cursor = lower
        if found is None:
            reply = {'status': 'missing'}
        else:
            f.seek(found)
            window = read_block(min(W, size - found))
            if not window.startswith(needle) or len(window) != min(W, size - found):
                raise ValueError()
            reply = {'status': 'found', 'offset': str(found), 'size': str(size),
                     'window': base64.b64encode(window).decode('ascii')}
except (OSError, ValueError):
    reply = {'status': 'error'}
sys.stdout.write(json.dumps(reply, separators=(',', ':')))
"""#
}
