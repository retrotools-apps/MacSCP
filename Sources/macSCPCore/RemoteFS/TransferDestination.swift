import Foundation

/// Remote names are single components, never paths supplied by a server.
enum TransferDestination {
    static func child(directory: String, name: String, local: Bool) throws -> String {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            throw RemoteFSError.finding(.unsafeTransferName)
        }
        let path = RemotePath.join(directory, name)
        if local {
            // A pre-existing link must not redirect a download outside its
            // selected directory, including a dangling link or directory link.
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw RemoteFSError.finding(.transferDestinationSymlink)
            }
        }
        return path
    }
}
