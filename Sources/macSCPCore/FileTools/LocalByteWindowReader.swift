import Foundation

extension LocalFileSystem: WindowedFileAccess {
    public func openWindowedFile(path: String) async throws -> any ByteWindowReader {
        try LocalByteWindowReader(path: path)
    }
}

private actor LocalByteWindowReader: ByteWindowReader {
    private var file: FileHandle?
    init(path: String) throws {
        file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    }
    func read(offset: UInt64, count: Int) async throws -> Data {
        try FileWindow.validate(offset: offset, count: count)
        try Task.checkCancellation()
        guard let file else { throw FileToolError.closed }
        try file.seek(toOffset: offset)
        return try file.read(upToCount: count) ?? Data()
    }
    func close() async {
        try? file?.close()
        file = nil
    }
}
