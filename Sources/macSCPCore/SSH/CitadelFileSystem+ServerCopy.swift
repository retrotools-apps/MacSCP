import Foundation

extension CitadelFileSystem: ServerSideFileCopying {
    public func validateServerCopy(sourceDirectory: String, destinationDirectory: String, name: String) async throws {
        let source = try Self.copyPath(sourceDirectory)
        let parent = try Self.copyPath(destinationDirectory)
        let target = try Self.copyPath(RemotePath.join(destinationDirectory, name))
        // pwd -P resolves directory aliases; checking the final destination too
        // prevents a pre-existing symlink from putting the copy inside its source.
        let command = "s=$(cd " + source + " && pwd -P) && d=$(cd " + parent
            + " && pwd -P) && t=\"$d\"/" + PosixQuoting.singleQuoted(name)
            + "; test -n \"$s\" && test -n \"$d\" && test \"$s\" != / || exit 1; "
            + "if test -d " + target + "; then t=$(cd " + target + " && pwd -P) || exit 1; fi; "
            + "case \"$t/\" in \"$s/\"*) exit 1;; esac"
        try await runServerCopyCommand(command)
    }

    public func copyFileOnServer(from source: String, to destination: String) async throws {
        let input = try Self.copyPath(source)
        let output = try Self.copyPath(destination)
        // POSIX cp refuses same-inode copies (including hard links). Refuse a
        // directory destination instead of letting cp silently append a basename.
        // No passwords, agents or additional SSH connections are involved.
        let copy = "test ! -d " + output + " && exec cp -p " + input + " " + output
        // Keep stdin open as a lifetime lease. Closing/cancelling the exec
        // channel produces EOF, so the remote watchdog terminates the copy.
        // read is a shell builtin: normal completion leaves no orphaned cat.
        let supervised = "exec 3<&0; (" + copy + ") & p=$!; "
            + "(read -r lease <&3; kill -TERM \"$p\" 2>/dev/null) & w=$!; "
            + "wait \"$p\"; r=$?; kill \"$w\" 2>/dev/null; wait \"$w\" 2>/dev/null; exit \"$r\""
        try await runServerCopyCommand(supervised)
    }

    private static func copyPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw RemoteFSError.protocolError(reason: CoreL10n.string("serverCopy.failed"))
        }
        return PosixQuoting.singleQuoted(path)
    }

    private func runServerCopyCommand(_ command: String) async throws {
        try Task.checkCancellation()
        do { try await performServerCopyCommand(command) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RemoteFSError.protocolError(reason: CoreL10n.string("serverCopy.failed")) }
        try Task.checkCancellation()
    }
}
