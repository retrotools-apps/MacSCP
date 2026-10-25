import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// A short-lived, owner-only local exchange. Secrets stay in memory, never in
/// helper files, environment variables or process arguments. No Keychain reads.
public final class SSHAskpassSession: Sendable {
    public struct Reply: Codable, Sendable {
        public let authorized: Bool
        public let answer: String?
    }
    struct Request: Codable, Sendable { let token: String; let prompt: String }
    struct Credential: Sendable { let prompts: Set<String>; let secret: String }
    struct State: Sendable {
        let token: String
        var credentials: [Credential]
        mutating func reply(to request: Request) -> Reply {
            guard request.token == token else { return Reply(authorized: false, answer: nil) }
            let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = credentials.indices.filter { credentials[$0].prompts.contains(prompt) }
            // OpenSSH prompts do not include ports. Ambiguous credentials must
            // be entered manually, never guessed from target/jump ordering.
            guard let index = matches.first,
                  Set(matches.map { credentials[$0].secret }).count == 1 else {
                return Reply(authorized: true, answer: nil)
            }
            return Reply(authorized: true, answer: credentials.remove(at: index).secret)
        }
    }

    public let helperURL: URL
    public let socketPath: String
    public let token: String
    private let directory: URL
    private let group: MultiThreadedEventLoopGroup
    private let server: any Channel
    private let state: NIOLockedValueBox<State>
    private let stopped = NIOLockedValueBox(false)

    static func credentials(for config: SSHConnectionConfig) -> [Credential] {
        func entry(host: String, username: String, auth: SSHConnectionConfig.AuthMethod) -> Credential? {
            switch auth {
            case .password(let value) where !value.isEmpty:
                let identity = "\(username)@\(host)"
                return Credential(prompts: ["\(identity)'s password:", "(\(identity)) Password:"], secret: value)
            case .privateKey(let path, let passphrase):
                guard let passphrase, !passphrase.isEmpty else { return nil }
                let expanded = NSString(string: path).expandingTildeInPath
                return Credential(prompts: ["Enter passphrase for key '\(path)':", "Enter passphrase for key '\(expanded)':"], secret: passphrase)
            default: return nil
            }
        }
        var result = [entry(host: config.host, username: config.username, auth: config.auth)].compactMap { $0 }
        if let jump = config.jump, let credential = entry(host: jump.host, username: jump.username, auth: jump.auth) {
            result.append(credential)
        }
        return result
    }

    public static func start(for config: SSHConnectionConfig, executable: URL) async throws -> SSHAskpassSession? {
        let credentials = credentials(for: config)
        guard !credentials.isEmpty else { return nil }
        // Keep AF_UNIX's short path limit even under macOS's long temp root.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ma-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let socketPath = directory.appendingPathComponent("s").path
        let token = UUID().uuidString + UUID().uuidString
        let state = NIOLockedValueBox(State(token: token, credentials: credentials))
        var listener: (any Channel)?
        do {
            let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AskpassServerHandler(state: state))
                }
            }.bind(unixDomainSocketPath: socketPath).get()
            listener = server
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
            let helper = directory.appendingPathComponent("a")
            let command = [executable.path, "--internal-ssh-askpass", socketPath, token]
                .map(PosixQuoting.singleQuoted).joined(separator: " ")
            let script = "#!/bin/sh\nexec \(command) \"$1\"\n"
            guard FileManager.default.createFile(atPath: helper.path, contents: Data(script.utf8),
                                                 attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return SSHAskpassSession(helper: helper, directory: directory, group: group, server: server, state: state, token: token)
        } catch {
            state.withLockedValue { $0.credentials.removeAll() }
            if let listener { try? await listener.close().get() }
            try? await group.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(helper: URL, directory: URL, group: MultiThreadedEventLoopGroup,
                 server: any Channel, state: NIOLockedValueBox<State>, token: String) {
        self.helperURL = helper
        self.directory = directory
        self.group = group
        self.server = server
        self.socketPath = directory.appendingPathComponent("s").path
        self.state = state
        self.token = token
    }

    public func stop() async {
        guard stopped.withLockedValue({ value in if value { return false }; value = true; return true }) else { return }
        state.withLockedValue { $0.credentials.removeAll() }
        try? await server.close().get()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: directory)
    }

    public static func request(socketPath: String, token: String, prompt: String) async throws -> Reply {
        guard prompt.utf8.count <= 4096 else { throw AskpassFailure.invalidFrame }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: Reply.self)
        var connection: (any Channel)?
        do {
            let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(AskpassReplyHandler(promise: promise))
                    }
                }.connect(unixDomainSocketPath: socketPath).get()
            connection = channel
            let request = try JSONEncoder().encode(Request(token: token, prompt: prompt))
            var bytes = channel.allocator.buffer(capacity: request.count + 1)
            bytes.writeBytes(request)
            bytes.writeInteger(UInt8(10))
            try await channel.writeAndFlush(bytes).get()
            let answer = try await promise.futureResult.get()
            try? await channel.close().get()
            try await group.shutdownGracefully()
            return answer
        } catch {
            promise.fail(error)
            if let connection { try? await connection.close().get() }
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private enum AskpassFailure: Error { case invalidFrame, timeout, closed }

private final class AskpassServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let state: NIOLockedValueBox<SSHAskpassSession.State>
    private var buffer = ByteBuffer()
    private var answered = false
    init(state: NIOLockedValueBox<SSHAskpassSession.State>) { self.state = state }
    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        context.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes <= 8192 else { context.close(promise: nil); return }
        guard let end = buffer.readableBytesView.firstIndex(of: 10) else { return }
        answered = true
        do {
            let bytes = Data(buffer.readableBytesView[..<end])
            let request = try JSONDecoder().decode(SSHAskpassSession.Request.self, from: bytes)
            let reply = state.withLockedValue { $0.reply(to: request) }
            let encoded = try JSONEncoder().encode(reply)
            var output = context.channel.allocator.buffer(capacity: encoded.count + 1)
            output.writeBytes(encoded)
            output.writeInteger(UInt8(10))
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(output)).whenComplete { _ in channel.close(promise: nil) }
        } catch { context.close(promise: nil) }
    }
}

private final class AskpassReplyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<SSHAskpassSession.Reply>
    private var buffer = ByteBuffer()
    private var timeout: Scheduled<Void>?
    init(promise: EventLoopPromise<SSHAskpassSession.Reply>) { self.promise = promise }
    func handlerAdded(context: ChannelHandlerContext) {
        let promise = self.promise
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(AskpassFailure.timeout)
            channel.close(promise: nil)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes <= 65536 else {
            promise.fail(AskpassFailure.invalidFrame); context.close(promise: nil); return
        }
        guard let end = buffer.readableBytesView.firstIndex(of: 10) else { return }
        timeout?.cancel()
        do {
            let reply = try JSONDecoder().decode(SSHAskpassSession.Reply.self, from: Data(buffer.readableBytesView[..<end]))
            promise.succeed(reply)
        } catch { promise.fail(error) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel()
        promise.fail(AskpassFailure.closed)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}
