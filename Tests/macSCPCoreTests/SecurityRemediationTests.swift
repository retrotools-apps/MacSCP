import Foundation
import MacSCPTestSupport
import Testing
@testable import macSCPCore

@Suite("Security remediation", .timeLimit(.minutes(2)))
struct SecurityRemediationTests {
    @Test func webDAVDiagnosticRejectsAnOversizedMetadataResponse() async throws {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\nConnection: close\r\n\r\n"
        let server = try LoopbackHTTPStub(response: response)
        defer { server.stop() }
        var values = WebDAVFieldSchema.defaults
        values[WebDAVField.baseURL] = "http://127.0.0.1:\(server.port)/dav"
        let step = await DiagnosticContribution.webdavOptions.run(
            values, DiagnosticContext(secrets: nil, sessionID: nil, timeout: .seconds(5)))
        #expect(step.outcome == .failed(RemoteFSFinding.metadataLimitExceeded.logSentence))
        #expect(server.acceptedConnections == 1)
    }

    @MainActor @Test func recursiveExpansionRejectsHostileDirectoriesAndCompletesOnce() async throws {
        let source = MockRemoteFileSystem(tree: [
            "/remote": [RemoteFileItem(name: "..", path: "/hostile", kind: .directory)]
        ])
        let destination = MockRemoteFileSystem(tree: ["/selected": []])
        let (events, completion) = AsyncStream<Void>.makeStream()
        var completions = 0
        let queue = TransferQueueViewModel()
        queue.enqueueTree(
            directoryName: "safe", direction: .download,
            source: source, sourceDirectory: "/remote",
            destination: destination, destinationDirectory: "/selected",
            onCompleted: { completions += 1; completion.yield(()); completion.finish() })
        for await _ in events { break }
        #expect(completions == 1)
        #expect(queue.items.contains { if case .failed = $0.status { true } else { false } })
    }

    @Test func sessionStoreRefusesEmbeddedCredentialsWithoutReplacingExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var session = StoredSession(name: "dav", kind: .webdav, webdav: StoredWebDAVConfig(
            baseURL: "https://example.invalid/dav", username: "user", useNextcloudPath: false))
        try store.upsert(session)
        session.webdav?.baseURL = "https://user:embedded@example.invalid/dav"
        #expect(throws: RemoteFSError.finding(.webDAVURLCredentials)) { try store.upsert(session) }
        #expect(try store.all().first?.webdav?.baseURL == "https://example.invalid/dav")
    }


    private var source: MockRemoteFileSystem {
        MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(name: "file", path: "/file", kind: .file, size: 3)]],
            files: ["/file": Data("new".utf8)])
    }

    @Test(arguments: ["", ".", "..", "../outside", "a/../../outside", "/outside", "bad\0name"])
    func rejectsUnsafeTransferNames(_ name: String) async throws {
        let destination = MockRemoteFileSystem(tree: ["/selected": []])
        await #expect(throws: RemoteFSError.finding(.unsafeTransferName)) {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/file", to: destination,
                destinationDirectory: "/selected", fileName: name, onProgress: { _ in })
        }
    }

    @Test(arguments: ["résumé.txt", "a b", "%2e%2e", "back\\slash", "a@b"])
    func preservesLegitimateTransferNames(_ name: String) async throws {
        let destination = MockRemoteFileSystem(tree: ["/selected": []])
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/file", to: destination,
            destinationDirectory: "/selected", fileName: name, onProgress: { _ in })
        #expect(await destination.writtenData(at: "/selected/" + name) == Data("new".utf8))
    }

    @Test func rejectsExistingLocalSymlinkWithoutModifyingTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("sentinel")
        let selected = directory.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: selected.appendingPathComponent("link"), withDestinationURL: outside)
        await #expect(throws: RemoteFSError.finding(.transferDestinationSymlink)) {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/file", to: LocalFileSystem(),
                destinationDirectory: selected.path, fileName: "link", onProgress: { _ in })
        }
        #expect(try Data(contentsOf: outside) == Data("original".utf8))
    }

    @Test(arguments: ["https://user:embedded@example.invalid/dav", "https://user@example.invalid/",
                      "https://:embedded@example.invalid/", "https://u%73er:p%40ss@example.invalid/",
                      "https://user:em/bedded@example.invalid/"])
    func rejectsWebDAVUserinfoAtRuntimePersistenceAndExport(_ url: String) throws {
        var values = WebDAVFieldSchema.defaults
        values[WebDAVField.baseURL] = url
        #expect(throws: (any Error).self) { try WebDAVFieldSchema.makeConfig(values, "") }
        var stored = StoredWebDAVConfig(baseURL: "https://example.invalid/", username: "user", useNextcloudPath: false)
        stored.baseURL = url
        #expect(throws: (any Error).self) { try JSONEncoder().encode(stored) }
        let exported = ExportedSession(id: UUID(), name: "test", kind: .webdav, fields: values.raw)
        #expect(throws: (any Error).self) { try JSONEncoder().encode(exported) }
    }

    @Test func safeWebDAVConfigurationRoundTrips() throws {
        let stored = StoredWebDAVConfig(baseURL: "https://example.invalid/dav", username: "user", useNextcloudPath: true)
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(StoredWebDAVConfig.self, from: data) == stored)
    }

    @Test(arguments: ["http://example.invalid/", " HTTP://example.invalid/ "])
    func cliRequiresExplicitHTTPConsent(_ url: String) throws {
        let config = ConnectionConfig.webdav(WebDAVConnectionConfig(
            baseURL: url, username: "user", useNextcloudPath: false, password: ""))
        #expect(throws: (any Error).self) {
            try PlaintextTransportGate.requireCLIConsent(for: config, allowed: false)
        }
        try PlaintextTransportGate.requireCLIConsent(for: config, allowed: true)
        let secure = ConnectionConfig.webdav(WebDAVConnectionConfig(
            baseURL: "https://example.invalid/", username: "", useNextcloudPath: false, password: ""))
        try PlaintextTransportGate.requireCLIConsent(for: secure, allowed: false)
    }

    @Test func paginationRejectsCyclesAndChangingTokensAtThePageLimit() throws {
        var cycle = S3ListingBudget()
        try cycle.consume(items: 1, bytes: 10, nextToken: "a")
        try cycle.consume(items: 1, bytes: 10, nextToken: "b")
        #expect(throws: (any Error).self) { try cycle.consume(items: 1, bytes: 10, nextToken: "a") }
        var endless = S3ListingBudget()
        for page in 1..<S3ListingBudget.maximumPages {
            try endless.consume(items: 0, bytes: 10, nextToken: String(page))
        }
        #expect(throws: (any Error).self) { try endless.consume(items: 0, bytes: 10, nextToken: "last") }
    }

    @Test func paginationBoundsBytesAndItems() throws {
        var bytes = S3ListingBudget()
        try bytes.consume(items: 0, bytes: S3ListingBudget.maximumBytes, nextToken: nil)
        #expect(throws: (any Error).self) { try bytes.consume(items: 0, bytes: 1, nextToken: nil) }
        var items = S3ListingBudget()
        try items.consume(items: S3ListingBudget.maximumItems, bytes: 0, nextToken: nil)
        #expect(throws: (any Error).self) { try items.consume(items: 1, bytes: 0, nextToken: nil) }
    }

    @Test func rejectsDeepXMLAndEntityDeclarations() throws {
        let deep = Data((String(repeating: "<x>", count: 65) + String(repeating: "</x>", count: 65)).utf8)
        #expect(throws: (any Error).self) { try MetadataXMLBudget.validate(deep) }
        let entity = Data("<!DOCTYPE x [<!ENTITY a 'expanded'>]><x>&a;</x>".utf8)
        #expect(throws: (any Error).self) { try MetadataXMLBudget.validate(entity) }
    }
}
