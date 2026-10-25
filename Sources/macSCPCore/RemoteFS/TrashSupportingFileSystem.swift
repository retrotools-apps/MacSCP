import Foundation

/// User-requested removal can be recoverable without changing the permanent
/// delete operations used by transfer cleanup and other backend maintenance.
public protocol TrashSupportingFileSystem: RemoteFileSystem {
    func moveToTrash(path: String) async throws
}

extension LocalFileSystem: TrashSupportingFileSystem {
    public func moveToTrash(path: String) async throws {
        try await Self.moveToTrash(path: path) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// The injectable operation lets tests verify routing and failures without
    /// touching the user's actual Trash. Never fall back to permanent deletion.
    static func moveToTrash(
        path: String, operation: @escaping @Sendable (URL) throws -> Void
    ) async throws {
        try Task.checkCancellation()
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/"), path != "/" else {
            throw RemoteFSError.permissionDenied(path: path)
        }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let targetPath = path
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try operation(url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: Self.map(error, path: targetPath))
                }
            }
        }
    }
}
