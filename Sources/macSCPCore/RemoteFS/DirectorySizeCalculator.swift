import Foundation

/// Logical content bytes, not allocated disk blocks (`du` can differ).
/// Uses the existing backend, never a shell, and never follows listed symlinks.
public enum DirectorySizeCalculator {
    public static func totalBytes(of directory: RemoteFileItem, on fs: any RemoteFileSystem) async throws -> UInt64 {
        guard directory.isDirectory else { return directory.size ?? 0 }
        var pending = [directory.path]
        var visited: Set<String> = []
        var total: UInt64 = 0
        while let path = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(path).inserted else { continue }
            let children = try await fs.list(path: path)
            try Task.checkCancellation()
            for child in children {
                try Task.checkCancellation()
                // Reconstruct the child path rather than trusting a server's
                // supplied path, and reject traversal components outright.
                guard !child.name.isEmpty, child.name != ".", child.name != "..",
                      !child.name.contains("/"), !child.name.contains("\0") else {
                    throw RemoteFSError.protocolError(reason: "Invalid directory entry")
                }
                let childPath = RemotePath.join(path, child.name)
                switch child.kind {
                case .directory: pending.append(childPath)
                case .file:
                    let size: UInt64
                    if let known = child.size { size = known }
                    else if let found = try await fs.stat(path: childPath).size { size = found }
                    else { throw RemoteFSError.protocolError(reason: "File size unavailable") }
                    let sum = total.addingReportingOverflow(size)
                    guard !sum.overflow else { throw RemoteFSError.protocolError(reason: "Directory size overflow") }
                    total = sum.partialValue
                case .symlink, .other: continue
                }
            }
        }
        return total
    }
}
