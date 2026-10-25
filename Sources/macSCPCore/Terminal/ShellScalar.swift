import Foundation

/// Unicode whitespace checks for SSH connection fields.
enum ShellScalar {
    static func isAnyUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }
}
