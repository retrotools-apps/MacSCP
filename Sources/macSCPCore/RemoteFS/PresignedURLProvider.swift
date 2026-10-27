import Foundation

/// The HTTP method a presigned URL is signed for: `.get` downloads the
/// object, `.put` uploads to it.
public enum PresignedMethod: String, Sendable {
    case get = "GET"
    case put = "PUT"
}

public protocol PresignedURLProvider: Sendable {
    func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL
}
