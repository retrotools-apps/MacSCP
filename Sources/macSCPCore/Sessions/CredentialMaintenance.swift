import Darwin
import Foundation

public enum CredentialMaintenance {
    /// Explicit maintenance command, never run on normal startup. Enumerates
    /// attributes and deletes former UUID slots without reading passwords.
    public static func runIfRequested(_ arguments: [String]) {
        guard arguments.dropFirst().first == "--internal-delete-old-credentials" else { return }
        do {
            let count = try SharedCredentialVault.deleteOldEntries()
            FileHandle.standardOutput.write(Data("Deleted \(count) old MacSCP credential entries.\n".utf8))
            Darwin.exit(0)
        } catch {
            FileHandle.standardError.write(Data("Credential cleanup failed: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }
}
