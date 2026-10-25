import Foundation

/// Builds the `ssh` command line an external terminal app will run (M11d).
///
/// This type is pure: it never touches the filesystem, spawns a process, or
/// reads the environment. That is what makes it exhaustively testable and
/// what keeps the security-critical property — no secret appears in scripts
/// or arguments, and every argument is quoted so a malicious host/username/path
/// cannot break out of its argument position — provable in isolation from
/// the process-launching code in the App layer (M11d Task 2).
public enum SSHCommandBuilder {
    /// The `ssh` argument vector for `config`, in the fixed order external
    /// tooling can rely on: optional TLS ProxyCommand/keepalive options,
    /// then `-p <port>` (only when
    /// non-default), `-l <username>`, `-i <keyPath>` (only for
    /// `.privateKey`), `-J <jumpUser>@<jumpHost>[:<jumpPort>]` (only when a
    /// plain jump is configured), or an explicit SSH ProxyCommand for a
    /// TLS-wrapped jump, then a literal `--` end-of-options marker, then
    /// the target host last.
    ///
    /// The `--` matters even though every argument is shell-quoted
    /// (`shellCommand(for:)`/`scriptContents(for:)`): quoting only stops the
    /// *shell* from splitting the host into extra words, it does nothing to
    /// stop *ssh itself* from parsing a host that starts with `-` as one of
    /// its own options (e.g. a host of `-V` makes ssh print its version and
    /// exit 0 instead of connecting, silently changing what the generated
    /// command does). `--` tells ssh's own argument parser that everything
    /// after it is positional, so the host is always treated as a literal
    /// hostname, never as an option.
    ///
    /// `.agent` and `.password` never contribute an argument of their own:
    /// with `.password`, `ssh` prompts interactively — no secret is ever
    /// passed on the command line or written anywhere by this builder.
    /// With `.privateKey`, only the key *path* is passed via `-i`; the
    /// passphrase (if any) is not representable in the ssh argument vector
    /// and is never read by this type.
    public static func arguments(for config: SSHConnectionConfig, tlsProxyExecutable: String? = nil) -> [String] {
        var args: [String] = []
        if let tunnel = config.tlsTunnel {
            // Missing helper fails closed; never fall back to direct SSH.
            let proxy = [tlsProxyExecutable ?? "/usr/bin/false", "--internal-tls-proxy",
                         tunnel.host, String(tunnel.port), tunnel.serverName,
                         tunnel.verifyCertificate ? "verify" : "no-verify"]
                .map { PosixQuoting.singleQuoted(escapedProxyTokens($0)) }
                .joined(separator: " ")
            args += ["-o", "ProxyCommand=" + proxy,
                     "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
        }

        if config.port != 22 {
            args.append("-p")
            args.append(String(config.port))
        }

        args.append("-l")
        args.append(config.username)

        if case .privateKey(let keyPath, _) = config.auth {
            args.append("-i")
            args.append(keyPath)
        }

        if let jump = config.jump {
            if jump.tlsTunnel != nil {
                // ProxyJump cannot attach transport options to the first hop.
                // Build that SSH client explicitly; both clients keep their own
                // host-key checks. Escape literal percent tokens once per parser.
                guard let hop = try? SSHConnectionConfig(host: jump.host, port: jump.port,
                    username: jump.username, auth: jump.auth, tlsTunnel: jump.tlsTunnel) else {
                    return ["-o", "ProxyCommand=/usr/bin/false", "--", config.host]
                }
                let hopArgs = arguments(for: hop, tlsProxyExecutable: tlsProxyExecutable)
                let prefix = (["/usr/bin/ssh"] + hopArgs.dropLast(2))
                    .map(nestedProxyArgument).joined(separator: " ")
                let host = PosixQuoting.singleQuoted(escapedProxyTokens(jump.host))
                args += ["-o", "ProxyCommand=" + prefix + " '-W' '[%h]:%p' '--' " + host]
            } else {
                args.append("-J")
                args.append(jumpTarget(for: jump))
            }
        }

        args.append("--")
        args.append(config.host)
        return args
    }

    /// Both OpenSSH's configuration tokenizer and the shell parse this layer.
    /// Nesting POSIX single-quote escapes can be rejected by the former even
    /// when the shell would accept them. Double quoting satisfies both parsers;
    /// escape shell substitutions and leave literal percent tokens for the next hop.
    private static func nestedProxyArgument(_ value: String) -> String {
        PosixQuoting.doubleQuoted(escapedProxyTokens(value))
    }

    private static func escapedProxyTokens(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            if scalar == "%" { escaped.unicodeScalars.append("%") }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }

    /// The full `ssh …` shell line, with every argument individually
    /// single-quoted (embedded `'` escaped as `'\''`). Quoting is the
    /// security boundary here: a host/username/key path containing shell
    /// metacharacters (`;`, `` ` ``, `$(...)`, whitespace, a quote) can never
    /// take effect, because it is always a value inside `'...'`, never
    /// unquoted shell syntax.
    public static func shellCommand(for config: SSHConnectionConfig, quietStartup: Bool = false,
                                    tlsProxyExecutable: String? = nil) -> String {
        // An explicit command suppresses OpenSSH's standard login/MOTD path.
        // A PTY and the user's login shell retain an interactive terminal.
        // Do not use -q or redirect stderr: host-key/auth failures must stay visible.
        let args = quietStartup
            ? ["-t"] + arguments(for: config, tlsProxyExecutable: tlsProxyExecutable) + [#"exec "${SHELL:-/bin/sh}" -l"#]
            : arguments(for: config, tlsProxyExecutable: tlsProxyExecutable)
        let quotedArguments = args.map(PosixQuoting.singleQuoted)
        return (["ssh"] + quotedArguments).joined(separator: " ")
    }

    /// The full disposable-script text: a `#!/bin/sh` shebang, a line that
    /// removes the script file itself before anything else runs, then
    /// `exec` into the quoted ssh command exactly once. Task 2 writes this
    /// text to a 0700 temp file and hands it to the external terminal app —
    /// this function only produces the text; it never touches a file.
    public static func scriptContents(for config: SSHConnectionConfig, tlsProxyExecutable: String? = nil,
                                     askpassHelperPath: String? = nil) -> String {
        let environment = askpassHelperPath.map {
            "export SSH_ASKPASS=\(PosixQuoting.singleQuoted($0))\nexport SSH_ASKPASS_REQUIRE=force\nexport DISPLAY=\"${DISPLAY:-:0}\"\n"
        } ?? ""
        return """
        #!/bin/sh
        rm -f -- "$0"
        if [ -t 1 ]; then printf '\\033[H\\033[2J'; fi
        \(environment)exec \(shellCommand(for: config, quietStartup: true, tlsProxyExecutable: tlsProxyExecutable))

        """
    }

    private static func jumpTarget(for jump: SSHConnectionConfig.Jump) -> String {
        // An IPv6 jump host must be bracketed (`[...]`), or real ssh fails
        // to parse the `-J` destination spec at all (verified: `-J
        // 'ju@2001:db8::1'` and `-J 'ju@2001:db8::1:2022'` both →
        // "Invalid -J argument", while `deploy@[2001:db8::1]:2022` parses
        // fine) — ssh cannot otherwise tell the host's own colons apart
        // from the `:<port>` suffix. A host containing `:` (including a
        // zone id like `fe80::1%en0`) is the IPv6-literal case; hostnames
        // and IPv4 addresses never contain `:` and stay unbracketed.
        let host = jump.host.contains(":") ? "[\(jump.host)]" : jump.host
        if jump.port != 22 {
            return "\(jump.username)@\(host):\(jump.port)"
        }
        return "\(jump.username)@\(host)"
    }
}
