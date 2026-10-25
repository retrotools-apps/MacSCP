import Foundation

public enum RemoteDirectorySearchMode: String, CaseIterable, Sendable {
    case name, contents
}

public protocol RemoteDirectorySearching: Sendable {
    func searchDirectory(path: String, query: String, mode: RemoteDirectorySearchMode) async throws -> [String]
}

/// Fixed commands only, with literal, quoted user data. Neither search follows
/// directory symlinks. Content matching runs on the SSH server, not on downloads.
public struct RemoteDirectorySearchCommand: Sendable {
    public static let outputLimit = 1024 * 1024
    private static let statusMarker = "\0MACSCP_SEARCH_STATUS="
    public let text: String
    public init(path: String, query: String, mode: RemoteDirectorySearchMode) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !query.isEmpty,
              !query.contains("\0"), query.utf8.count <= FileWindow.maximumQueryBytes else {
            throw FileToolError.invalidQuery
        }
        let search: String
        switch mode {
        case .contents:
            let recursive = "LC_ALL=C grep -r -a -l -F --null -- "
                + PosixQuoting.singleQuoted(query) + " " + PosixQuoting.singleQuoted(path)
            // GNU/BSD grep can return NUL-delimited names in one process.
            // BusyBox lacks that option: keep filenames safe with find's
            // argument batching rather than parsing line-delimited output.
            let batch = "query=$1; shift; result=0; for file do "
                + "if grep -q -F -e \"$query\" \"$file\"; then printf '%s\\000' \"$file\" || exit 2; "
                + "else code=$?; if [ \"$code\" -ne 1 ]; then result=2; fi; fi; done; exit \"$result\""
            let fallback = "( find " + PosixQuoting.singleQuoted(path) + " -type f -exec sh -c "
                + PosixQuoting.singleQuoted(batch) + " sh " + PosixQuoting.singleQuoted(query)
                + " {} +; code=$?; if [ \"$code\" -eq 0 ]; then exit 0; else exit 2; fi )"
            search = "if { grep -a -F --null -e '' /dev/null >/dev/null 2>&1; test \"$?\" -le 1; }; then "
                + recursive + "; else " + fallback + "; fi"
        case .name:
            var literal = ""
            for scalar in query.unicodeScalars {
                if "\\*?[]".unicodeScalars.contains(scalar) { literal.append("\\") }
                literal.unicodeScalars.append(scalar)
            }
            search = "find " + PosixQuoting.singleQuoted(path) + " -type f -name "
                + PosixQuoting.singleQuoted("*" + literal + "*") + " -print0"
        }
        // Bound output at its producer, not just in our consumer: Citadel's
        // exec stream can buffer data ahead of the consuming task. The final
        // NUL-delimited status preserves grep/find errors through the pipeline.
        let script = search + "; status=$?; printf '\\000MACSCP_SEARCH_STATUS=%s\\000' \"$status\""
        text = "sh -c " + PosixQuoting.singleQuoted(script)
            + " 2>/dev/null | head -c " + String(Self.outputLimit + 1)
    }

    public static func results(_ data: Data, mode: RemoteDirectorySearchMode) throws -> [String] {
        guard data.count <= outputLimit else { throw FileToolError.resultsTooLarge }
        let marker = Data(statusMarker.utf8)
        guard data.last == 0, let range = data.range(of: marker, options: .backwards),
              let code = Int(String(decoding: data[range.upperBound..<data.index(before: data.endIndex)], as: UTF8.self)) else {
            throw FileToolError.commandFailed(-1)
        }
        guard code == 0 || (mode == .contents && code == 1) else { throw FileToolError.commandFailed(code) }
        guard let output = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw FileToolError.commandFailed(-1)
        }
        return output.split(separator: "\0").map(String.init)
    }
}
