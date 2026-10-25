import Foundation

public enum PosixQuoting {
    /// A shell word for a layer that also passes through OpenSSH's option
    /// tokenizer. Unlike nested single-quote escapes, this form is accepted
    /// by both parsers. Every shell expansion character is escaped by scalar,
    /// including when followed by a Unicode combining mark.
    public static func doubleQuoted(_ value: String) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "\"" || scalar == "$" || scalar == "`" {
                quoted.unicodeScalars.append("\\")
            }
            quoted.unicodeScalars.append(scalar)
        }
        quoted.unicodeScalars.append("\"")
        return quoted
    }

    /// `value` wrapped in single quotes, with any embedded `'` written as
    /// `'\''` — close the quote, an escaped literal quote, reopen.
    ///
    /// Single quotes because a POSIX shell expands nothing inside them:
    /// `$`, backtick and backslash are all literal. `'` is the sole
    /// exception, which is what the escape handles.
    ///
    /// Written as a walk over `Unicode.Scalar`s — the unit `ShellScalar`
    /// documents — and NOT as `replacingOccurrences(of: "'", with: "'\\''")`.
    /// That call matches on extended grapheme clusters and canonical
    /// equivalence, so an apostrophe carrying a combining mark is not an
    /// occurrence of `'` to it, is left unescaped, and meets the closing
    /// quote of this very wrapper as live shell syntax. `echo {{X}}` plus
    /// such a value executed arbitrary commands in real `bash`. A scalar
    /// walk cannot have that bug, and it cannot be reverted to the one-line
    /// form without the reverter having to delete this paragraph.
    public static func singleQuoted(_ value: String) -> String {
        var quoted = "'"
        for scalar in value.unicodeScalars {
            if scalar == "'" {
                quoted += "'\\''"
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
        quoted.unicodeScalars.append("'")
        return quoted
    }
}
