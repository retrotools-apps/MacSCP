import Crypto
import Foundation
import MacSCPTestSupport
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@Suite("SSH event-loop isolation compatibility", .timeLimit(.minutes(1)))
struct SSHConcurrencyCompatibilityTests {
    @Test(arguments: [true, false])
    func realLocalHandshakePreservesAuthenticationAndHostKeyValidation(matchingHostKey: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var server: Channel?
        var client: Channel?
        do {
            let listener = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    do {
                        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
                        let handler = NIOSSHHandler(
                            role: .server(.init(hostKeys: [.init(ed25519Key: key)], userAuthDelegate: FixturePassword())),
                            allocator: channel.allocator, inboundChildChannelInitializer: nil)
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(handler)
                        }
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }
                .bind(host: "127.0.0.1", port: 0)
            server = try await awaitCancellably(listener)
            let address = try #require(server?.localAddress)
            let authenticated = group.next().makePromise(of: Void.self)
            let connection = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    let handler = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: SimplePasswordDelegate(username: "fixture", password: FixturePassword.password),
                            serverAuthDelegate: FixtureHostKey(seed: matchingHostKey ? 7 : 8))),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(handler, AuthenticationCompletion(authenticated))
                    }
                }
                .connect(to: address)
            client = try await awaitCancellably(connection)
            do {
                try await awaitCancellably(authenticated.futureResult)
                #expect(matchingHostKey)
                let channel = try #require(client)
                // Exercise global-request callbacks and a denied response, too.
                let request = channel.eventLoop.flatSubmit {
                    do {
                        let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                        let promise = channel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                        handler.sendTCPForwardingRequest(.listen(host: "127.0.0.1", port: 0), promise: promise)
                        return promise.futureResult
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }
                do {
                    _ = try await awaitCancellably(request)
                    Issue.record("The default server delegate must reject port forwarding")
                } catch {
                    #expect(error is NIOSSHError)
                }
            } catch FixtureFailure.hostKeyMismatch {
                #expect(!matchingHostKey)
            }
        } catch {
            if let client { try? await client.close().get() }
            if let server { try? await server.close().get() }
            try await group.shutdownGracefully()
            throw error
        }
        if let client { try? await client.close().get() }
        if let server { try? await server.close().get() }
        try await group.shutdownGracefully()
    }

    @Test func authenticationMetadataCanCrossTasks() async {
        let methods = await Task.detached { NIOSSHAvailableUserAuthenticationMethods.password }.value
        let certificate = await Task.detached { NIOSSHCertifiedPublicKey.CertificateType.user }.value
        let response = await Task.detached { GlobalRequest.TCPForwardingResponse(boundPort: 12345) }.value
        #expect(methods.contains(.password))
        #expect(certificate == .user)
        #expect(response.boundPort == 12345)
    }
}

private enum FixtureFailure: Error { case hostKeyMismatch, closedBeforeAuthentication }

private struct FixturePassword: NIOSSHServerUserAuthenticationDelegate {
    static let password = "local-test-password"
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let value) = request.request, value.password == Self.password {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

private struct FixtureHostKey: NIOSSHClientServerAuthenticationDelegate {
    let seed: UInt8
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
            guard hostKey == NIOSSHPrivateKey(ed25519Key: key).publicKey else {
                validationCompletePromise.fail(FixtureFailure.hostKeyMismatch)
                return
            }
            validationCompletePromise.succeed(())
        } catch { validationCompletePromise.fail(error) }
    }
}

private final class AuthenticationCompletion: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<Void>
    private var completed = false
    init(_ promise: EventLoopPromise<Void>) { self.promise = promise }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !completed {
            completed = true
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            completed = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(FixtureFailure.closedBeforeAuthentication)
        }
        context.fireChannelInactive()
    }
}
