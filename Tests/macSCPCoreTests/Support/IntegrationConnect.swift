import Foundation
@testable import macSCPCore

func connectWithRetry<Connection>(
    _ make: () async throws -> Connection
) async throws -> Connection {
    do {
        return try await make()
    } catch {
        try? await Task.sleep(for: .milliseconds(500))
        return try await make()
    }
}
