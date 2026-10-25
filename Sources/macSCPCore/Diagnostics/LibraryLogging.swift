import Logging

/// Raw third-party logging is never sent to stderr. The app's own diagnostic
/// sink provides the opt-in, credential-safe record instead.
public enum LibraryLogging {
    /// Called once by the executable before creating any dependency loggers.
    public static func bootstrap() {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
    }
}
