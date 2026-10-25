import Darwin
import Dispatch
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Shared TLS encapsulation for Citadel and OpenSSH ProxyCommand. Both paths
/// verify TLS by default. An explicit session opt-out applies identically to
/// both paths; SSH host-key verification is independent and never disabled.
public enum SSHTLSTransport {
    static func failureDescription(for error: any Error) -> String? {
        guard error is NIOSSLError else { return nil }
        return CoreL10n.string("core.connect.tlsNegotiationFailed")
    }
    /// Only the headless helper enters Swift's asynchronous runtime. The GUI
    /// follows a synchronous App.main() entry point, with no enclosing task.
    public static func runProxyMainIfRequested(_ arguments: [String]) {
        guard arguments.dropFirst().first == "--internal-tls-proxy" else { return }
        Task.detached {
            let status = await runProxyIfRequested(arguments) ?? 1
            Darwin.exit(status)
        }
        dispatchMain()
    }

    static func handlers(for tunnel: SSHTLSTunnelConfig) throws -> [any ChannelHandler] {
        [try handler(for: tunnel), TLSHandshakeMonitor()]
    }

    public static func exitIfProxyRequested(_ arguments: [String]) async {
        if let status = await runProxyIfRequested(arguments) { Darwin.exit(status) }
    }
    static func handler(for tunnel: SSHTLSTunnelConfig) throws -> NIOSSLClientHandler {
        let context = try NIOSSLContext(configuration: configuration(verifyCertificate: tunnel.verifyCertificate))
        return try NIOSSLClientHandler(context: context, serverHostname: tunnel.serverName)
    }

    static func configuration(verifyCertificate: Bool = true) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = verifyCertificate ? .fullVerification : .none
        return configuration
    }

    /// The app executable also acts as a byte-only ProxyCommand helper. No
    /// Keychain access, GUI, SSH authentication or secret arguments on this path.
    public static func runProxyIfRequested(_ arguments: [String]) async -> Int32? {
        guard arguments.dropFirst().first == "--internal-tls-proxy" else { return nil }
        do {
            guard arguments.count == 6, let port = Int(arguments[3]),
                  ["verify", "no-verify"].contains(arguments[5]) else {
                throw RemoteFSError.protocolError(reason: CoreL10n.string("core.connect.invalidTLSTunnel"))
            }
            let tunnel = try SSHTLSTunnelConfig(host: arguments[2], port: port,
                                              serverName: arguments[4], verifyCertificate: arguments[5] == "verify")
            try await proxyStdio(through: tunnel)
            return 0
        } catch {
            let detail = failureDescription(for: error) ?? error.localizedDescription
            let message = String(format: CoreL10n.string("core.tlsProxy.failed %@"), detail)
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return 1
        }
    }

    private static func proxyStdio(through tunnel: SSHTLSTunnelConfig) async throws {
        let input = dup(STDIN_FILENO)
        let output = dup(STDOUT_FILENO)
        guard input >= 0, output >= 0 else {
            if input >= 0 { Darwin.close(input) }
            if output >= 0 { Darwin.close(output) }
            throw POSIXError(.EBADF)
        }
        let group = MultiThreadedEventLoopGroup.singleton
        let stdio: any Channel
        do {
            stdio = try await NIOPipeBootstrap(group: group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .takingOwnershipOfDescriptors(input: input, output: output).get()
        } catch {
            Darwin.close(input)
            Darwin.close(output)
            throw error
        }
        do {
            let context = try NIOSSLContext(configuration: configuration(verifyCertificate: tunnel.verifyCertificate))
            let inputGate = BytePumpReadGate()
            let failure = TLSFailureBox()
            let remote = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    do {
                        let tls = try NIOSSLClientHandler(context: context, serverHostname: tunnel.serverName)
                        // Bootstrap initializers already execute on this
                        // channel's event loop; do not transfer non-Sendable
                        // handlers through an asynchronous pipeline overload.
                        try channel.pipeline.syncOperations.addHandlers(tls, TLSHandshakeMonitor(failure: failure))
                        // Gate stdin until TCP is connected. The TLS handler
                        // buffers SSH bytes until certificate verification.
                        return BytePump.install(local: channel, remote: stdio, remoteReadGate: inputGate)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: tunnel.host, port: tunnel.port).get()
            inputGate.open()
            do {
                _ = try await stdio.closeFuture.and(remote.closeFuture).get()
                if let error = failure.error { throw error }
            } catch {
                try? await remote.close()
                // A pipe-close/write error must not hide the TLS failure that
                // caused it (for example a rejected server certificate).
                throw failure.error ?? error
            }
        } catch {
            try? await stdio.close()
            throw error
        }
    }
}

/// The error crosses NIO event loops and the proxy's async task; all access
/// is serialized. Only the first failure is kept, never traffic or credentials.
private final class TLSFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var first: (any Error)?
    func record(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = error }
    }
    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }
}

/// Bound TLS negotiation itself, not just the preceding TCP connect. Once
/// negotiated, the SSH protocol owns integrity, keepalive and session lifetime.
private final class TLSHandshakeMonitor: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let failure: TLSFailureBox?
    private var deadline: Scheduled<Void>?
    private var completed = false
    init(failure: TLSFailureBox? = nil) { self.failure = failure }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.pipeline.fireErrorCaught(POSIXError(.ETIMEDOUT))
            channel.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted = event {
            completed = true
            deadline?.cancel()
            deadline = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // After verified negotiation, EOF is reported to OpenSSH, which
        // independently checks SSH framing/MACs and its disconnect message.
        if !completed || (error as? NIOSSLError) != .uncleanShutdown { failure?.record(error) }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        deadline = nil
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
}
