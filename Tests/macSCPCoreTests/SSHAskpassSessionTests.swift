import Foundation
import Testing
import Crypto
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import NIOSSH
@testable import macSCPCore

private final class AskpassBundleAnchor: NSObject {}

@Suite("External SSH credential exchange", .timeLimit(.minutes(1)))
struct SSHAskpassSessionTests {
    private func config() throws -> SSHConnectionConfig {
        try SSHConnectionConfig(host: "target.invalid", username: "target",
            auth: .password("local-target-fixture"),
            jump: .init(host: "bastion.invalid", username: "jump", auth: .password("local-jump-fixture")))
    }

    @Test func matchesTargetAndJumpIndependentlyAndConsumesEachAnswerOnce() throws {
        var state = SSHAskpassSession.State(token: "nonce", credentials: SSHAskpassSession.credentials(for: try config()))
        let unauthorized = state.reply(to: .init(token: "wrong", prompt: "target@target.invalid's password:"))
        #expect(!unauthorized.authorized)
        #expect(unauthorized.answer == nil)
        let unknown = state.reply(to: .init(token: "nonce", prompt: "other@target.invalid's password:"))
        #expect(unknown.authorized)
        #expect(unknown.answer == nil)
        let jump = state.reply(to: .init(token: "nonce", prompt: "jump@bastion.invalid's password: "))
        let target = state.reply(to: .init(token: "nonce", prompt: "target@target.invalid's password:"))
        let correct = jump.answer == "local-jump-fixture" && target.answer == "local-target-fixture"
        #expect(correct)
        #expect(state.reply(to: .init(token: "nonce", prompt: "target@target.invalid's password:")).answer == nil)
        #expect(state.credentials.isEmpty)
    }

    @Test func ambiguousPasswordsAreNeverGuessed() throws {
        let config = try SSHConnectionConfig(host: "same.invalid", username: "user", auth: .password("first-fixture"),
            jump: .init(host: "same.invalid", port: 2222, username: "user", auth: .password("second-fixture")))
        var state = SSHAskpassSession.State(token: "nonce", credentials: SSHAskpassSession.credentials(for: config))
        #expect(state.reply(to: .init(token: "nonce", prompt: "user@same.invalid's password:")).answer == nil)
        #expect(state.credentials.count == 2)
    }

    @Test func passphrasesMatchOnlyTheExpectedKeyPath() throws {
        let config = try SSHConnectionConfig(host: "target.invalid", username: "user",
            auth: .privateKey(keyPath: "~/.ssh/fixture", passphrase: "local-key-fixture"))
        var state = SSHAskpassSession.State(token: "nonce", credentials: SSHAskpassSession.credentials(for: config))
        #expect(state.reply(to: .init(token: "nonce", prompt: "Enter passphrase for key '/other':")).answer == nil)
        let path = NSString(string: "~/.ssh/fixture").expandingTildeInPath
        let answer = state.reply(to: .init(token: "nonce", prompt: "Enter passphrase for key '\(path)':"))
        let correct = answer.answer == "local-key-fixture"
        #expect(correct)
    }

    @Test func localSocketAndRealHelperTransmitSecretsWithoutPersistingThem() async throws {
        let executable = Bundle(for: AskpassBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MacSCP")
        let config = try config()
        let broker = try #require(try await SSHAskpassSession.start(for: config, executable: executable))
        do {
            let script = try String(contentsOf: broker.helperURL, encoding: .utf8)
            let launch = SSHCommandBuilder.scriptContents(for: config, askpassHelperPath: broker.helperURL.path)
            let noSecrets = ![script, launch].contains { $0.contains("local-target-fixture") || $0.contains("local-jump-fixture") }
            #expect(noSecrets)
            for (path, mode) in [(broker.helperURL.path, 0o700), (broker.socketPath, 0o600),
                                  (broker.helperURL.deletingLastPathComponent().path, 0o700)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
            }
            let denied = try await SubprocessRunner.run(executable,
                arguments: ["--internal-ssh-askpass", broker.socketPath, "wrong", "target@target.invalid's password:"], timeout: .seconds(10))
            #expect(denied.status == 1)
            #expect(denied.stdout.isEmpty)
            let jump = try await SubprocessRunner.run(broker.helperURL,
                arguments: ["jump@bastion.invalid's password:"], timeout: .seconds(10))
            let target = try await SubprocessRunner.run(broker.helperURL,
                arguments: ["target@target.invalid's password:"], timeout: .seconds(10))
            #expect(jump.status == 0)
            #expect(target.status == 0)
            let correct = jump.stdoutText == "local-jump-fixture\n" && target.stdoutText == "local-target-fixture\n"
            #expect(correct)
            #expect(jump.stderr.isEmpty && target.stderr.isEmpty)
        } catch {
            await broker.stop()
            throw error
        }
        await broker.stop()
        await broker.stop()
        #expect(!FileManager.default.fileExists(atPath: broker.helperURL.deletingLastPathComponent().path))
    }

    @Test func agentAndRedactedPasswordsCreateNoExchange() async throws {
        for config in [try SSHConnectionConfig(host: "target.invalid", username: "user", auth: .agent),
                       try config().redactingSecrets()] {
            let broker = try await SSHAskpassSession.start(for: config, executable: URL(fileURLWithPath: "/unused"))
            #expect(broker == nil)
        }
    }

    @Test func realOpenSSHAutomaticallyAuthenticatesAgainstAPinnedLocalServer() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let accepted = NIOLockedValueBox(false)
        let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32)))
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let serverKey = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32)))
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [serverKey], userAuthDelegate: AskpassPasswordFixture(accepted: accepted))),
                    allocator: channel.allocator, inboundChildChannelInitializer: nil))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("askpass-ssh-\(UUID())")
        let executable = Bundle(for: AskpassBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MacSCP")
        var broker: SSHAskpassSession?
        do {
            let port = try #require(server.localAddress?.port)
            let config = try SSHConnectionConfig(host: "127.0.0.1", port: port, username: "fixture", auth: .password("local-openssh-fixture"))
            broker = try await SSHAskpassSession.start(for: config, executable: executable)
            let exchange = try #require(broker)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let known = directory.appendingPathComponent("known_hosts")
            let pin = "[127.0.0.1]:\(port) \(String(openSSHPublicKey: key.publicKey))\n"
            #expect(FileManager.default.createFile(atPath: known.path, contents: Data(pin.utf8)))
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = exchange.helperURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
            let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ["-F", "/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(known.path)",
                            "-o", "PreferredAuthentications=password", "-o", "NumberOfPasswordPrompts=1", "-T"]
                    + SSHCommandBuilder.arguments(for: config) + ["true"],
                environment: environment, timeout: .seconds(10))
            let didAuthenticate = accepted.withLockedValue { $0 }
            #expect(didAuthenticate, Comment(rawValue: result.stderrText))
            // The fixture deliberately rejects shell channels after authentication.
            #expect(result.status != 0)
        } catch {
            if let broker { await broker.stop() }
            try? await server.close().get()
            try await group.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        if let broker { await broker.stop() }
        try? await server.close().get()
        try await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct AskpassPasswordFixture: NIOSSHServerUserAuthenticationDelegate {
    let accepted: NIOLockedValueBox<Bool>
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        let matches: Bool
        if case .password(let value) = request.request {
            matches = request.username == "fixture" && value.password == "local-openssh-fixture"
        } else { matches = false }
        accepted.withLockedValue { $0 = $0 || matches }
        responsePromise.succeed(matches ? .success : .failure)
    }
}
