import Foundation

/// An explicitly selected transfer route, not an automatically inferred backend optimization.
/// The caller must establish that both panes address the same account and SSH route.
public protocol ServerSideFileCopying: RemoteFileSystem {
    func validateServerCopy(sourceDirectory: String, destinationDirectory: String, name: String) async throws
    func copyFileOnServer(from source: String, to destination: String) async throws
}

/// Transfer-scoped source view. Metadata and directory planning still use SFTP;
/// file contents never enter the client. Unsupported server commands fail closed.
public struct ServerSideCopyFileSystem: RemoteFileSystem {
    private let base: any ServerSideFileCopying
    private let root: String
    private let destinationDirectory: String
    private let name: String

    public init(base: any ServerSideFileCopying, sourceDirectory: String,
                destinationDirectory: String, name: String) {
        self.base = base
        root = sourceDirectory
        self.destinationDirectory = destinationDirectory
        self.name = name
    }

    public func copyFile(from source: String, to destination: String) async throws {
        try Task.checkCancellation()
        try await base.copyFileOnServer(from: source, to: destination)
        try Task.checkCancellation()
    }

    public func validateDirectoryCopy(at path: String) async throws {
        guard path == root else { return }
        try await base.validateServerCopy(sourceDirectory: root, destinationDirectory: destinationDirectory, name: name)
    }

    public func list(path: String) async throws -> [RemoteFileItem] {
        return try await base.list(path: path)
    }
    public func stat(path: String) async throws -> RemoteFileItem { try await base.stat(path: path) }
    public func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        // Never silently turn this route into a client-mediated copy.
        throw RemoteFSError.protocolError(reason: CoreL10n.string("serverCopy.failed"))
    }
    public func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        throw RemoteFSError.protocolError(reason: CoreL10n.string("serverCopy.failed"))
    }
    public func delete(path: String) async throws { try await base.delete(path: path) }
    public func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    public func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    public func setPermissions(path: String, permissions: UInt32) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }
    public func deleteTree(at path: String) async throws { try await base.deleteTree(at: path) }
    public func homeDirectoryPath() async throws -> String { try await base.homeDirectoryPath() }
    public func disconnect() async {} // This view does not own the connection.
}
