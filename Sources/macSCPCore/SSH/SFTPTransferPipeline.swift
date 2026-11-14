import Foundation

/// Bounded payload requests on one SFTP handle. Offsets, rather than reply order,
/// determine file order. Structured tasks drain before the owner closes the file.
enum SFTPTransferPipeline {
    // Citadel splits larger writes into sequential 32,000-byte requests.
    static let requestBytes = 32_000
    static let depth = 64
    static let windowBytes = 2 * 1024 * 1024

    static func readBatch(
        from offset: UInt64,
        read: @escaping @Sendable (UInt64, Int) async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for index in 0..<depth {
                group.addTask {
                    var bytes = Data()
                    // SFTP permits short DATA replies before EOF. Fill each
                    // range so a short reply cannot leave a hole in the file.
                    while bytes.count < requestBytes {
                        try Task.checkCancellation()
                        let part = try await read(offset + UInt64(index * requestBytes + bytes.count),
                                                  requestBytes - bytes.count)
                        try Task.checkCancellation()
                        guard !part.isEmpty else { break }
                        guard part.count <= requestBytes - bytes.count else {
                            throw RemoteFSError.protocolError(reason: "Oversized SFTP read reply")
                        }
                        bytes.append(part)
                    }
                    return (index, bytes)
                }
            }
            var ranges = Array(repeating: Data(), count: depth)
            for try await (index, bytes) in group { ranges[index] = bytes }
            try Task.checkCancellation()
            var result = Data()
            for bytes in ranges {
                result.append(bytes)
                if bytes.count < requestBytes { break }
            }
            return result
        }
    }

    static func write(
        contents: AsyncThrowingStream<Data, Error>, from offset: UInt64,
        write: @escaping @Sendable (Data, UInt64) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextOffset = offset
            var pending = 0
            for try await chunk in contents {
                var index = 0
                while index < chunk.count {
                    try Task.checkCancellation()
                    if pending == depth {
                        try await group.next()
                        pending -= 1
                    }
                    let end = min(index + requestBytes, chunk.count)
                    let bytes = Data(chunk[chunk.startIndex + index..<chunk.startIndex + end])
                    let position = nextOffset
                    group.addTask {
                        try Task.checkCancellation()
                        try await write(bytes, position)
                        try Task.checkCancellation()
                    }
                    pending += 1
                    nextOffset += UInt64(bytes.count)
                    index = end
                }
            }
            try await group.waitForAll()
            try Task.checkCancellation()
        }
    }
}
