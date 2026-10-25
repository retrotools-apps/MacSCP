import Foundation

/// Bounds a complete operation, including servers that keep changing tokens.
struct S3ListingBudget {
    static let maximumPages = 128
    static let maximumItems = 100_000
    static let maximumBytes = 64 * 1024 * 1024
    private var pages = 0
    private var items = 0
    private var bytes = 0
    private var tokens = Set<String>()

    mutating func consume(items count: Int, bytes size: Int, nextToken: String?) throws {
        pages += 1
        items += count
        bytes += size
        guard pages <= Self.maximumPages, items <= Self.maximumItems,
              bytes <= Self.maximumBytes else {
            throw RemoteFSError.finding(.metadataLimitExceeded)
        }
        if let nextToken {
            guard !nextToken.isEmpty, nextToken.utf8.count <= 8192,
                  tokens.insert(nextToken).inserted,
                  pages < Self.maximumPages else {
                throw RemoteFSError.finding(.paginationInvalid)
            }
        }
    }
}
