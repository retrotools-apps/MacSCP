import AppKit
import Foundation
import macSCPCore

/// Opens an SSH session in an external terminal app (M11d).
///
/// The connection is never automated through AppleScript or an app-specific
/// bridge — that would need a new entitlement. Instead this writes a
/// disposable `.command` script (built by the pure, security-reviewed
/// `SSHCommandBuilder`) into its own 0700 temp file and hands it to
/// macOS, which opens it with the chosen terminal app. A cold Terminal launch
/// uses `open --fresh` to suppress restoration through Launch Services;
/// running applications receive a normal `NSWorkspace` document-open request.
/// The script removes itself
/// before `exec`ing into `ssh` (see `SSHCommandBuilder.scriptContents`), so
/// nothing lingers after launch except while the app is still starting up.
@MainActor
enum ExternalTerminalLauncher {
    enum LaunchError: Error, Equatable {
        /// The chosen app (name for `.terminalApp`/`.iTerm`, path for
        /// `.custom`) could not be resolved to a launchable application.
        case applicationNotFound(String)
        /// `target == .custom` but no app has been chosen yet (`customPath`
        /// is nil/empty) — distinct from `.applicationNotFound`, which
        /// always names a concrete (but unusable) app/path (review finding
        /// I-1, M11d final review): without this case the empty path fell
        /// through to `.applicationNotFound("")` and the alert named
        /// nothing ("Couldn't find “”.").
        case noCustomAppChosen
        /// The disposable script could not be written; `String` is the
        /// underlying reason (e.g. an `Error`'s description).
        case scriptWriteFailed(String)
        /// `NSWorkspace` accepted the launch request but it failed
        /// asynchronously (e.g. a damaged/quarantined bundle); `String` is
        /// the underlying reason (review finding I-2, M11d final review).
        case launchFailed(String)
    }

    private static let terminalAppBundleID = "com.apple.Terminal"
    private static let iTermBundleID = "com.googlecode.iterm2"
    private static var pendingTerminalLaunch: Task<Void, any Error>?
    private static var credentialSessions: [UUID: SSHAskpassSession] = [:]
    static var hasCredentialSessions: Bool { !credentialSessions.isEmpty }

    /// Root temp directory for disposable launch scripts — its own
    /// subfolder, mirroring `EditSessionManager`'s `macscp-edit` (M5e/M6a):
    /// swept as a whole at app launch (`sweepOrphanedTempDirectories`), and
    /// each script also removes itself once `ssh` starts (`scriptContents`).
    /// `nonisolated`: a default-parameter expression is evaluated outside
    /// the enclosing type's actor context, so a `@MainActor`-isolated
    /// property can't serve as one — this touches no actor-isolated state
    /// anyway (just `FileManager`/`String`).
    nonisolated static var defaultRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-terminal", isDirectory: true)
    }

    /// Writes `config`'s script to a fresh `<root>/<uuid>.command` (0700)
    /// and opens it with the app resolved from `target`/`customPath`.
    ///
    /// `async throws` (not the `completionHandler: nil` fire-and-forget this
    /// used to be, review finding I-2): `NSWorkspace`'s launch can fail
    /// AFTER being accepted — a damaged or quarantined bundle, for
    /// instance — and that failure must reach the caller the same way every
    /// other `LaunchError` does, not vanish silently while leaving the
    /// disposable script behind.
    static func open(
        config: SSHConnectionConfig, target: TerminalTarget, customPath: String?,
        root: URL = defaultRoot
    ) async throws {
        let appURL = try resolveApplication(target: target, customPath: customPath)
        guard let executable = Bundle.main.executableURL else {
            throw LaunchError.scriptWriteFailed(CocoaError(.fileReadNoSuchFile).localizedDescription)
        }
        let credentials = try await SSHAskpassSession.start(for: config, executable: executable)
        let credentialID = UUID()
        if let credentials {
            credentialSessions[credentialID] = credentials
            // Enough time for terminal startup and an explicit host-key decision.
            Task {
                try? await Task.sleep(for: .seconds(300))
                await credentials.stop()
                credentialSessions.removeValue(forKey: credentialID)
            }
        }
        var scriptURL: URL?
        do {
            let written = try writeScript(for: config, root: root, askpassHelperPath: credentials?.helperURL.path)
            scriptURL = written
            try await openScript(written, withApplicationAt: appURL, target: target)
        } catch {
            if let scriptURL { try? FileManager.default.removeItem(at: scriptURL) }
            if let credentials { await credentials.stop() }
            credentialSessions.removeValue(forKey: credentialID)
            if let error = error as? LaunchError { throw error }
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }

    /// Only a cold Terminal launch may discard saved windows. No forced new instance.
    static func freshLaunchArguments(target: TerminalTarget, application: URL, script: URL, isRunning: Bool) -> [String]? {
        guard target == .terminalApp, !isRunning else { return nil }
        return ["-F", "-a", application.path, "--", script.path]
    }

    static func launchConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        return configuration
    }

    private static func openScript(_ script: URL, withApplicationAt application: URL, target: TerminalTarget) async throws {
        // A simultaneous request waits for the cold launch, then opens its own document.
        if target == .terminalApp, let pendingTerminalLaunch { try await pendingTerminalLaunch.value }
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: terminalAppBundleID).isEmpty
        if let arguments = freshLaunchArguments(target: target, application: application, script: script, isRunning: isRunning) {
            let launch = Task {
                let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: arguments, timeout: .seconds(20))
                guard result.status == 0 else {
                    throw LaunchError.launchFailed(result.stderrText.isEmpty
                        ? POSIXError(.EIO).localizedDescription : result.stderrText)
                }
            }
            pendingTerminalLaunch = launch
            defer { pendingTerminalLaunch = nil }
            try await launch.value
        } else {
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: application,
                configuration: launchConfiguration())
        }
    }

    static func stopCredentialSessions() async {
        let sessions = Array(credentialSessions.values)
        credentialSessions.removeAll()
        for session in sessions { await session.stop() }
    }

    /// Removes the entire `macscp-terminal` temp tree at app launch, mirror
    /// image of `EditSessionManager.sweepOrphanedTempDirectories`: a
    /// hard-killed previous run may have left a script behind (the normal
    /// case is self-deletion right after `ssh` starts, see
    /// `SSHCommandBuilder.scriptContents`). No script can be "in use" at
    /// launch time (scripts are disposable and single-shot), so sweeping the
    /// whole tree is safe. Idempotent; a missing tree is a no-op.
    static func sweepOrphanedTempDirectories(root: URL = defaultRoot) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Resolves `target`/`customPath` to an application URL, or throws
    /// `.applicationNotFound` — never a fallback to a different app.
    private static func resolveApplication(target: TerminalTarget, customPath: String?) throws -> URL {
        switch target {
        case .terminalApp:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalAppBundleID)
            else { throw LaunchError.applicationNotFound("Terminal") }
            return url
        case .iTerm:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleID)
            else { throw LaunchError.applicationNotFound("iTerm") }
            return url
        case .custom:
            guard let customPath, !customPath.isEmpty else {
                throw LaunchError.noCustomAppChosen
            }
            guard isValidCustomApp(atPath: customPath) else {
                throw LaunchError.applicationNotFound(customPath)
            }
            return URL(fileURLWithPath: customPath)
        }
    }

    static func isValidCustomApp(atPath path: String?) -> Bool {
        guard let path, !path.isEmpty,
            FileManager.default.fileExists(atPath: path),
            Bundle(path: path)?.bundleIdentifier != nil
        else { return false }
        return true
    }

    /// Writes `SSHCommandBuilder.scriptContents(for:)` to a fresh UUID-named
    /// `.command` file under `root`, created with 0700 permissions from the
    /// start (`FileManager.createFile(atPath:contents:attributes:)`) —
    /// NEVER create-then-`chmod`, which would briefly leave the script
    /// (containing the target host/username/key path) world-readable.
    private static func writeScript(for config: SSHConnectionConfig, root: URL, askpassHelperPath: String?) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw LaunchError.scriptWriteFailed(error.localizedDescription)
        }
        let scriptURL = root.appendingPathComponent("\(UUID().uuidString).command")
        guard let data = SSHCommandBuilder.scriptContents(
            for: config, tlsProxyExecutable: Bundle.main.executableURL?.path,
            askpassHelperPath: askpassHelperPath).data(using: .utf8) else {
            throw LaunchError.scriptWriteFailed(scriptURL.lastPathComponent)
        }
        let created = FileManager.default.createFile(
            atPath: scriptURL.path(percentEncoded: false), contents: data,
            attributes: [.posixPermissions: 0o700])
        guard created else {
            throw LaunchError.scriptWriteFailed(scriptURL.lastPathComponent)
        }
        return scriptURL
    }
}
