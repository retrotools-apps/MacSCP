import Foundation

/// Pipelined destinations may contain holes after a dropped connection. Their
/// length alone is insufficient evidence that an interrupted prefix is intact.
public protocol ResumePrefixValidatingFileSystem: RemoteFileSystem {}

enum ResumePrefixValidation {
    static func matches(
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationPath: String, count: UInt64
    ) async throws -> Bool {
        let sourceStream = try await source.readStream(path: sourcePath, fromOffset: 0)
        let destinationStream = try await destination.readStream(path: destinationPath, fromOffset: 0)
        var left = sourceStream.makeAsyncIterator()
        var right = destinationStream.makeAsyncIterator()
        var a = Data(), b = Data()
        var ai = 0, bi = 0
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            while ai == a.count {
                guard let next = try await left.next() else { return false }
                a = next; ai = 0
                try Task.checkCancellation()
                if !a.isEmpty { break }
            }
            while bi == b.count {
                guard let next = try await right.next() else { return false }
                b = next; bi = 0
                try Task.checkCancellation()
                if !b.isEmpty { break }
            }
            let length = min(a.count - ai, b.count - bi, Int(min(remaining, UInt64(Int.max))))
            guard a[a.startIndex + ai..<a.startIndex + ai + length]
                == b[b.startIndex + bi..<b.startIndex + bi + length] else { return false }
            ai += length; bi += length
            remaining -= UInt64(length)
        }
        return true
    }
}
