import NIOCore
import NIOSSH

extension SSHClient {
    /// SSH-level traffic crosses every enclosing jump/TLS transport, without
    /// opening SFTP, executing commands or allocating a remote listener.
    /// A missing reply closes the transport, allowing its owner to reconnect.
    public func sendKeepAlive(timeout: TimeAmount) async throws {
        try await eventLoop.flatSubmit { [session = self.session] in
            let response = session.channel.eventLoop.makePromise(of: Void.self)
            let deadline = session.channel.eventLoop.scheduleTask(in: timeout) {
                session.channel.close(promise: nil)
            }
            response.futureResult.whenComplete { _ in deadline.cancel() }
            session.sshHandler.value.sendKeepAlive(promise: response)
            return response.futureResult
        }.get()
    }
}
