import AppKit
import Foundation
import os
import macSCPCore

/// Resolves which application should open a downloaded remote file for
/// editing (double-click wiring, M5e/T4).
///
/// 1. `settings.associatedApp(forExtension:)` — a per-extension rule.
/// 2. `settings.defaultEditorPath` — the configured default editor.
/// 3. No configured application: MacSCP's built-in editor.
///
/// A configured app path that no longer exists on disk is skipped (falls
/// through to the next stage) with a single log line — not treated as fatal.
enum EditorResolver {
    private static let logger = Logger(subsystem: "retroTools.MacSCP", category: "EditorResolver")

    /// Stages 1-2 (pre-download): resolves the extension rule or the
    /// configured default editor by file name alone — no local file needs to
    /// exist yet. Returns `nil` if neither yields an app that still exists on
    /// disk, meaning the caller should use the built-in editor.
    ///
    /// `@MainActor` because `SettingsStore` is — call sites (the App layer)
    /// are already on the main actor.
    @MainActor
    static func applicationURL(forFileName fileName: String, settings: SettingsStore) -> URL? {
        let ext = (fileName as NSString).pathExtension
        if let associatedPath = settings.associatedApp(forExtension: ext) {
            if FileManager.default.fileExists(atPath: associatedPath) {
                return URL(fileURLWithPath: associatedPath)
            }
            if DiagnosticLog.shared.isEnabled(.error) {
                logger.warning(
                    "configured file association app for '.\(ext, privacy: .public)' not found at \(associatedPath, privacy: .public); falling through"
                )
            }
        }
        if let defaultPath = settings.defaultEditorPath {
            if FileManager.default.fileExists(atPath: defaultPath) {
                return URL(fileURLWithPath: defaultPath)
            }
            if DiagnosticLog.shared.isEnabled(.error) {
                logger.warning(
                    "configured default editor not found at \(defaultPath, privacy: .public); falling through"
                )
            }
        }
        return nil
    }

}
