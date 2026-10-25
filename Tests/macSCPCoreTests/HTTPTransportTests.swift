import Foundation
import Testing
@testable import macSCPCore

@Suite("HTTPTransport")
struct HTTPTransportTests {
    @Test func headAllowsLargeObjectLengthWithoutBufferingAFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedMetadataStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(session: session, maximumResponseBytes: 4)
        var request = URLRequest(url: URL(string: "https://example.invalid/oversized")!)
        request.httpMethod = "HEAD"
        let (data, response) = try await transport.send(request)
        #expect(response.statusCode == 200)
        #expect(data.isEmpty)
    }
    @Test(arguments: ["missing", "understated", "oversized"])
    func rejectsOversizedBodiesRegardlessOfDeclaredLength(_ mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedMetadataStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(session: session, maximumResponseBytes: 4)
        await #expect(throws: RemoteFSError.finding(.metadataLimitExceeded)) {
            _ = try await transport.send(URLRequest(url: URL(string: "https://example.invalid/" + mode)!))
        }
    }

    @Test func acceptsBodyAtExactLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedMetadataStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(session: session, maximumResponseBytes: 5)
        let (data, _) = try await transport.send(URLRequest(url: URL(string: "https://example.invalid/missing")!))
        #expect(data == Data("12345".utf8))
    }

    /// The transport must use the session it was handed, not `.shared` —
    /// WebDAV depends on this to get its delegate (auth + server trust) into
    /// the request path at all.
    @Test func usesTheInjectedSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTransportStubURLProtocol.self]
        let transport = URLSessionHTTPTransport(session: URLSession(configuration: configuration))

        let (data, response) = try await transport.send(
            URLRequest(url: URL(string: "https://example.invalid/probe")!))

        #expect(response.statusCode == 218)
        #expect(String(data: data, encoding: .utf8) == "stubbed")
    }

    /// `send`'s `as? HTTPURLResponse` guard, the only route to it: a plain
    /// `URLResponse` is a shape `URLSession` itself will not hand back for a
    /// real http(s) request, so the ONLY seam that reaches this guard is a
    /// stub `URLProtocol` answering with a non-`HTTPURLResponse` — the seam
    /// `usesTheInjectedSession` above already establishes for this suite
    /// (typed-remote-fs-findings Task 5).
    @Test func sendThrowsTheNonHTTPResponseFindingForANonHTTPResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPResponseStubURLProtocol.self]
        let transport = URLSessionHTTPTransport(session: URLSession(configuration: configuration))

        await #expect(throws: RemoteFSError.finding(.nonHTTPResponse)) {
            _ = try await transport.send(URLRequest(url: URL(string: "https://example.invalid/probe")!))
        }
    }

    /// `sendStreaming`'s own `as? HTTPURLResponse` guard — a separate call
    /// than `send`'s, over `session.bytes(for:)` rather than
    /// `session.data(for:)`, so it needs its own drive through the same stub.
    @Test func sendStreamingThrowsTheNonHTTPResponseFindingForANonHTTPResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPResponseStubURLProtocol.self]
        let transport = URLSessionHTTPTransport(session: URLSession(configuration: configuration))

        await #expect(throws: RemoteFSError.finding(.nonHTTPResponse)) {
            _ = try await transport.sendStreaming(
                URLRequest(url: URL(string: "https://example.invalid/probe")!))
        }
    }
}

final class BoundedMetadataStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers: [String: String] = [:]
        if request.url?.lastPathComponent == "understated" { headers["Content-Length"] = "1" }
        if request.url?.lastPathComponent == "oversized" { headers["Content-Length"] = "100" }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: Data("12345".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers every request with a plain `URLResponse` — never an
/// `HTTPURLResponse` — so `URLSessionHTTPTransport.send`/`sendStreaming`'s
/// `as? HTTPURLResponse` guard fails and `.nonHTTPResponse` is what gets
/// thrown. Registered only on the ephemeral configuration above, so it
/// cannot leak into other suites.
final class NonHTTPResponseStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = URLResponse(
            url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers every request with 218 and a fixed body. Registered only on the
/// ephemeral configuration above, so it cannot leak into other suites.
final class HTTPTransportStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 218, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("stubbed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
