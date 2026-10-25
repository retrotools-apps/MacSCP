import CryptoKit
import Foundation

// Validate configuration before compiling the app. Never print secret input.
let text = ProcessInfo.processInfo.environment["MACSCP_SPARKLE_PRIVATE_KEY", default: ""]
    .trimmingCharacters(in: .whitespacesAndNewlines)
let publicPath = CommandLine.arguments.dropFirst().first ?? "Resources/Sparkle-public-key.txt"
do {
    guard let secret = Data(base64Encoded: text), [32, 96].contains(secret.count) else {
        fputs("error: MACSCP_SPARKLE_PRIVATE_KEY must contain the Sparkle private-key export, not a filename or public key\n", stderr)
        exit(1)
    }
    let expected = try String(contentsOfFile: publicPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let actual: Data
    if secret.count == 32 {
        actual = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
    } else {
        // Legacy Sparkle export: 64-byte hashed secret followed by public key.
        // The workflow's signing probe also exercises the private half.
        actual = Data(secret.suffix(32))
    }
    guard actual.base64EncodedString() == expected else {
        fputs("error: Sparkle private-key export does not match Resources/Sparkle-public-key.txt; do not rotate the public key to bypass this check\n", stderr)
        exit(1)
    }
    if CommandLine.arguments.count == 4 {
        let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let signatureText = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = Data(base64Encoded: signatureText) ?? Data()
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: actual)
        guard key.isValidSignature(signature, for: payload) else {
            fputs("error: Sparkle signing probe failed public-key verification\n", stderr)
            exit(1)
        }
    }
    print("Sparkle signing key matches the application public key")
} catch {
    fputs("error: unable to validate Sparkle signing configuration\n", stderr)
    exit(1)
}
