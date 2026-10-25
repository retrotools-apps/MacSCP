import Foundation
import Testing
import NIOCore
import NIOEmbedded
import Synchronization
@testable import Citadel
@testable import macSCPCore

@Suite("Release security boundaries", .timeLimit(.minutes(1)))
struct ReleaseSecurityBoundaryTests {
    @Test func exportFieldBagRejectsCredentials() throws {
        let endpoint = "https://fixture:fixture@host.test"
        let exported = ExportedSession(id: UUID(), name: "test", kind: .s3,
                                       fields: [S3Field.endpoint.rawValue: endpoint])
        #expect(throws: (any Error).self) { try JSONEncoder().encode(exported) }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "name": "test", "kind": "s3",
            "fields": [S3Field.endpoint.rawValue: endpoint]
        ])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ExportedSession.self, from: data) }
    }

    @Test func redirectsKeepRangeAndValidator() async throws {
        let config = S3ConnectionConfig(accessKeyID: "test", secretAccessKey: "test", region: "test",
            endpoint: "https://s3.example.test", bucket: "test", usePathStyle: true, sessionToken: nil)
        let delegate = S3RedirectSessionDelegate(config: config)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://s3.example.test/a")!)
        request.setValue("bytes=12-", forHTTPHeaderField: "Range")
        request.setValue("\"version-one\"", forHTTPHeaderField: "If-Match")
        let task = session.dataTask(with: request)
        for path in ["b", "c"] {
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            let proposed = URLRequest(url: URL(string: "https://s3.example.test/\(path)")!)
            let result = Mutex<URLRequest?>(nil)
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: proposed, completionHandler: { request in result.withLock { $0 = request } })
            let redirected = try #require(result.withLock { $0 })
            #expect(redirected.value(forHTTPHeaderField: "Range") == "bytes=12-")
            #expect(redirected.value(forHTTPHeaderField: "If-Match") == "\"version-one\"")
            let signed = redirected.value(forHTTPHeaderField: "Authorization") != nil
            #expect(signed)
            request = redirected
        }
    }

    @Test func directoryReaderBoundsEmptyBatchesAndClosesOnSuccess() async throws {
        for endless in [true, false] {
            let invalidated = Mutex(false)
            let closed = Mutex(false)
            let entries = Mutex(0)
            var limits = SFTPDirectoryLimits()
            limits.responses = 3
            let operation = {
                try await SFTPDirectoryReader.read(path: "/test", limits: limits, nextID: { 1 }, send: { request in
                    switch request {
                    case .realpath:
                        return .name(.init(requestId: 1, components: [.init(filename: "/test", longname: "", attributes: .init())]))
                    case .opendir: return .handle(.init(requestId: 1, handle: ByteBuffer()))
                    case .readdir:
                        let count = entries.withLock { $0 += 1; return $0 }
                        if endless || count == 1 { return .name(.init(requestId: 1, components: [])) }
                        return .status(.init(requestId: 1, errorCode: .eof, message: "", languageTag: ""))
                    case .closeFile:
                        closed.withLock { $0 = true }
                        return .status(.init(requestId: 1, errorCode: .ok, message: "", languageTag: ""))
                    default: throw SFTPError.invalidResponse
                    }
                }, invalidate: { invalidated.withLock { $0 = true } })
            }
            if endless {
                await #expect(throws: (any Error).self) { try await operation() }
                #expect(invalidated.withLock { $0 })
                #expect(entries.withLock { $0 } == 3)
            } else {
                let result = try await operation()
                #expect(result.count == 1)
                #expect(closed.withLock { $0 })
                #expect(!invalidated.withLock { $0 })
            }
        }
    }

    @Test(arguments: ["items", "metadata", "canonicalization"])
    func directoryReaderRejectsResourceExhaustion(_ boundary: String) async throws {
        let invalidated = Mutex(false)
        var limits = SFTPDirectoryLimits()
        limits.items = 1
        limits.metadataBytes = 128
        let requests = Mutex(0)
        await #expect(throws: (any Error).self) {
            try await SFTPDirectoryReader.read(path: "/test", limits: limits, nextID: { 1 }, send: { request in
                requests.withLock { $0 += 1 }
                switch request {
                case .realpath(let request):
                    let path = boundary == "canonicalization" && request.path == "/test" ? "/different" : "/test"
                    return .name(.init(requestId: 1, components: [.init(filename: path, longname: "", attributes: .init())]))
                case .opendir: return .handle(.init(requestId: 1, handle: ByteBuffer()))
                case .readdir:
                    let entry = SFTPPathComponent(filename: "entry", longname: "entry", attributes: .init())
                    return .name(.init(requestId: 1, components: boundary == "items" ? [entry, entry] : [entry]))
                default: throw SFTPError.invalidResponse
                }
            }, invalidate: { invalidated.withLock { $0 = true } })
        }
        #expect(invalidated.withLock { $0 })
        #expect(requests.withLock { $0 } <= 3)
    }

    @Test(arguments: [false, true])
    func ordinaryDirectoryRefusalKeepsSubsystemUsable(_ atOpen: Bool) async throws {
        let invalidated = Mutex(false)
        do {
            _ = try await SFTPDirectoryReader.read(path: "/missing", nextID: { 1 }, send: { request in
                if case .realpath = request, atOpen {
                    return .name(.init(requestId: 1, components: [.init(filename: "/missing", longname: "", attributes: .init())]))
                }
                return .status(.init(requestId: 1, errorCode: .noSuchFile, message: "", languageTag: ""))
            }, invalidate: { invalidated.withLock { $0 = true } })
            Issue.record("Missing directory was accepted")
        } catch let status as SFTPMessage.Status {
            #expect(status.errorCode == .noSuchFile)
        }
        #expect(!invalidated.withLock { $0 })
    }
    @Test(arguments: ["https://user:fixture@host.test", "user:fixture@host.test",
                      "https://user%40host.test", "https://user:12/path@host.test"])
    func credentialEndpointsAreRejected(_ endpoint: String) throws {
        let config = StoredS3Config(accessKeyID: "test", region: "test", endpoint: endpoint,
                                    bucket: "test", usePathStyle: true)
        #expect(throws: (any Error).self) { try JSONEncoder().encode(config) }
        let data = try JSONSerialization.data(withJSONObject: [
            "accessKeyID": "test", "region": "test", "endpoint": endpoint,
            "bucket": "test", "usePathStyle": true, "startsAtBucketList": false
        ])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StoredS3Config.self, from: data) }
        #expect(S3FieldSchema.endpointComponents(endpoint) == nil)
    }

    @Test(arguments: ["https://s3.example.test", "minio.lan:9000", "https://[::1]:9000"])
    func validEndpointsRoundTrip(_ endpoint: String) throws {
        let config = StoredS3Config(accessKeyID: "test", region: "test", endpoint: endpoint,
                                    bucket: "test", usePathStyle: true)
        #expect(try JSONDecoder().decode(StoredS3Config.self, from: JSONEncoder().encode(config)) == config)
        #expect(S3FieldSchema.endpointComponents(endpoint) != nil)
    }

    @Test(arguments: ["", "<Error><Code>InternalError</Code></Error>", "<Other/>",
                      "<CompleteMultipartUploadResult><Error/></CompleteMultipartUploadResult>",
                      "<CompleteMultipartUploadResult>"])
    func invalidCompletionIsNotSuccess(_ xml: String) {
        #expect(throws: (any Error).self) { try S3MultipartXML.validateCompletion(Data(xml.utf8)) }
    }

    @Test func namespacedCompletionIsAccepted() throws {
        try S3MultipartXML.validateCompletion(Data(" \n<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><ETag>test</ETag></CompleteMultipartUploadResult>".utf8))
    }

    actor Pulls {
        var count = 0
        func next() -> Data? { count += 1; return count <= 4 ? Data([UInt8(count)]) : nil }
    }

    @Test func webDAVPullsOnlyOnDemand() async throws {
        let pulls = Pulls()
        let source = AsyncThrowingStream<Data, Error>(unfolding: { await pulls.next() })
        let wrapped = WebDAVFileSystem.surfacing(source)
        #expect(await pulls.count == 0)
        var iterator = wrapped.makeAsyncIterator()
        #expect(try await iterator.next() == Data([1]))
        #expect(await pulls.count == 1)
        #expect(try await iterator.next() == Data([2]))
        #expect(await pulls.count == 2)
    }

    @Test func webDAVResumeDropsOnlyRequiredPrefix() async throws {
        let pulls = Pulls()
        let source = AsyncThrowingStream<Data, Error>(unfolding: { await pulls.next() })
        let wrapped = WebDAVFileSystem.dropping(2, from: source)
        #expect(await pulls.count == 0)
        var iterator = wrapped.makeAsyncIterator()
        #expect(try await iterator.next() == Data([3]))
        #expect(await pulls.count == 3)
        #expect(try await iterator.next() == Data([4]))
    }

    @Test(arguments: [UInt32(0), SFTPResourceLimits.maximumPacketBytes + 1, UInt32.max])
    func sftpRejectsInvalidLengthBeforePayload(_ length: UInt32) throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        defer { _ = try? channel.finish() }
        var header = ByteBufferAllocator().buffer(capacity: 4)
        header.writeInteger(length)
        #expect(throws: (any Error).self) { try channel.writeInbound(header) }
    }

    @Test func sftpAcceptsFragmentedValidFrame() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        defer { _ = try? channel.finish() }
        var frame = ByteBufferAllocator().buffer(capacity: 9)
        frame.writeInteger(UInt32(5)); frame.writeInteger(SFTPMessageType.initialize.rawValue)
        frame.writeInteger(UInt32(3))
        let slice = frame.readSlice(length: 3)
        let prefix = try #require(slice)
        _ = try channel.writeInbound(prefix)
        #expect(try channel.readInbound(as: SFTPMessage.self) == nil)
        _ = try channel.writeInbound(frame)
        #expect(try channel.readInbound(as: SFTPMessage.self) != nil)
    }
}
