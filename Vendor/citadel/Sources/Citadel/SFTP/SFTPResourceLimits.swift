import NIO

/// Above the client's transfer chunks, with finite peer-controlled aggregation.
enum SFTPResourceLimits {
    static let maximumPacketBytes: UInt32 = 8 * 1024 * 1024
}

struct SFTPDirectoryLimits: Sendable {
    var canonicalizationRequests = 16
    var responses = 32_768
    var items = 1_000_000
    var metadataBytes = 64 * 1024 * 1024
}

enum SFTPDirectoryReader {
    static func read(
        path initialPath: String, limits: SFTPDirectoryLimits = .init(),
        nextID: @Sendable () -> UInt32,
        send: @Sendable (SFTPRequest) async throws -> SFTPResponse,
        invalidate: @Sendable () -> Void
    ) async throws -> [SFTPMessage.Name] {
        var ownsHandle = false
        do {
            var path = initialPath
            var visited: Set<String> = []
            var attempts = 0
            while true {
                try Task.checkCancellation()
                guard attempts < limits.canonicalizationRequests, visited.insert(path).inserted else {
                    throw SFTPError.resourceLimitExceeded
                }
                attempts += 1
                let response = try await send(.realpath(.init(requestId: nextID(), path: path)))
                if case .status(let status) = response { throw status }
                guard case .name(let name) = response,
                      !name.components.isEmpty else { throw SFTPError.invalidResponse }
                let resolved = name.path
                if resolved == path { break }
                path = resolved
            }
            try Task.checkCancellation()
            let opened = try await send(.opendir(.init(requestId: nextID(), handle: path)))
            if case .status(let status) = opened { throw status }
            guard case .handle(let handle) = opened else {
                throw SFTPError.invalidResponse
            }
            ownsHandle = true
            var names: [SFTPMessage.Name] = []
            var responses = 0
            var itemCount = 0
            var bytes = 0
            while true {
                try Task.checkCancellation()
                guard responses < limits.responses else { throw SFTPError.resourceLimitExceeded }
                responses += 1
                let response = try await send(.readdir(.init(requestId: nextID(), handle: handle.handle)))
                switch response {
                case .name(let name):
                    guard name.components.count <= limits.items - itemCount else { throw SFTPError.resourceLimitExceeded }
                    itemCount += name.components.count
                    for component in name.components {
                        // Include per-entry overhead and extension strings, not just batches.
                        var lengths = [128, component.filename.utf8.count, component.longname.utf8.count]
                        for (key, value) in component.attributes.extended { lengths += [key.utf8.count, value.utf8.count] }
                        for length in lengths {
                            guard length <= limits.metadataBytes - bytes else { throw SFTPError.resourceLimitExceeded }
                            bytes += length
                        }
                    }
                    names.append(name)
                case .status(let status) where status.errorCode == .eof:
                    guard case .status(let closed) = try await send(.closeFile(.init(requestId: nextID(), handle: handle.handle))),
                          closed.errorCode == .ok else { throw SFTPError.invalidResponse }
                    return names
                case .status(let status): throw status
                default: throw SFTPError.invalidResponse
                }
            }
        } catch {
            // Closing the subsystem releases handles even if the peer ignores CLOSE.
            // An ordinary path refusal before OPENDIR allocated a handle
            // leaves the subsystem usable for the next navigation.
            if ownsHandle || !(error is SFTPMessage.Status) { invalidate() }
            throw error
        }
    }
}
