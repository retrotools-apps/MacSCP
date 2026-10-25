import Foundation

enum SSHKeyFileSelection {
    static func initialDirectory(currentPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard !currentPath.isEmpty else { return home.appendingPathComponent(".ssh", isDirectory: true) }
        let expanded = currentPath.hasPrefix("~/")
            ? home.appendingPathComponent(String(currentPath.dropFirst(2))).path
            : currentPath
        guard expanded.hasPrefix("/") else { return home.appendingPathComponent(".ssh", isDirectory: true) }
        return URL(fileURLWithPath: expanded).deletingLastPathComponent()
    }
}
