import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Independent implementation of WinSCP's master-password wire format:
/// PBKDF2-HMAC-SHA1/1000, AES-256 with a little-endian counter starting at 1,
/// HMAC-SHA1 truncated to 10 bytes, and the external-password A35D marker.
/// The low iteration count is required for interoperability, not a new KDF choice.
enum WinSCPPasswordCipher {
    // Fixed permutation required by WinSCP's public password-scrambling format.
    private static let permutation: [UInt8] = [
        0,223,235,233,240,185,88,102,22,130,27,53,79,125,66,201,
        90,71,51,60,134,104,172,244,139,84,91,12,123,155,237,151,
        192,6,87,32,211,38,149,75,164,145,52,200,224,226,156,50,
        136,190,232,63,129,209,181,120,28,99,168,94,198,40,238,112,
        55,217,124,62,227,30,36,242,208,138,174,231,26,54,214,148,
        37,157,19,137,187,111,228,39,110,17,197,229,118,246,153,80,
        21,128,69,117,234,35,58,67,92,7,132,189,5,103,10,15,
        252,195,70,147,241,202,107,49,20,251,133,76,204,73,203,135,
        184,78,194,183,1,121,109,11,143,144,171,161,48,205,245,46,
        31,72,169,131,239,160,25,207,218,146,43,140,127,255,81,98,
        42,115,173,142,114,13,2,219,57,56,24,126,3,230,47,215,
        9,44,159,33,249,18,93,95,29,113,220,89,97,182,248,64,
        68,34,4,82,74,196,213,165,179,250,108,254,59,14,236,175,
        85,199,83,106,77,178,167,225,45,247,163,158,8,221,61,191,
        119,16,253,105,186,23,170,100,216,65,162,122,150,176,154,193,
        206,222,188,152,210,243,96,41,86,180,101,177,166,141,212,116
    ]

    static func random(_ count: Int) throws -> Data {
        var result = Data(count: count)
        let status = result.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw WinSCPINIError.crypto }
        return result
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    static func unhex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count <= 8192 else { throw WinSCPINIError.invalid }
        func digit(_ byte: UInt8) throws -> UInt8 {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: throw WinSCPINIError.invalid
            }
        }
        var result = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            result.append(try digit(bytes[index]) * 16 + digit(bytes[index + 1]))
        }
        return result
    }

    private static func keys(_ master: String, salt: Data) throws -> Data {
        guard !master.isEmpty, master.utf8.count <= 4096, salt.count == 16 else { throw WinSCPINIError.masterRequired }
        var key = Data(count: 66)
        let password = Array(master.utf8)
        let status = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { input in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.bindMemory(to: Int8.self).baseAddress,
                        password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                        output.bindMemory(to: UInt8.self).baseAddress, 66)
                }
            }
        }
        guard status == kCCSuccess else { throw WinSCPINIError.crypto }
        return key
    }

    private static func crypt(_ input: Data, key: Data) throws -> Data {
        let blocks = (input.count + 15) / 16
        var counters = Data(count: blocks * 16)
        for block in 0..<blocks {
            let counter = UInt64(block + 1)
            for index in 0..<8 { counters[block * 16 + index] = UInt8(truncatingIfNeeded: counter >> (index * 8)) }
        }
        var stream = Data(count: counters.count + 16)
        let capacity = stream.count
        var written = 0
        let status = stream.withUnsafeMutableBytes { output in
            counters.withUnsafeBytes { bytes in
                key.withUnsafeBytes { secret in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        secret.baseAddress, 32, nil, bytes.baseAddress, counters.count,
                        output.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess, written == counters.count else { throw WinSCPINIError.crypto }
        return Data(zip(input, stream).map(^))
    }

    private static func mac(_ encrypted: Data, keys: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: encrypted, using: SymmetricKey(data: keys[32..<64])).prefix(10))
    }

    private static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func seal(_ plaintext: Data, master: String, salt: Data) throws -> Data {
        let derived = try keys(master, salt: salt)
        let encrypted = try crypt(plaintext, key: Data(derived.prefix(32)))
        return salt + encrypted + mac(encrypted, keys: derived)
    }

    static func open(_ sealed: Data, master: String) throws -> Data {
        guard sealed.count > 26 else { throw WinSCPINIError.invalid }
        let derived = try keys(master, salt: Data(sealed.prefix(16)))
        let encrypted = Data(sealed.dropFirst(16).dropLast(10))
        guard equal(mac(encrypted, keys: derived), Data(sealed.suffix(10))) else { throw WinSCPINIError.wrongMaster }
        return try crypt(encrypted, key: Data(derived.prefix(32)))
    }

    static func verifier(master: String, salt: Data? = nil, dummy: Data? = nil) throws -> String {
        let salt = try salt ?? random(16)
        let dummy = try dummy ?? random(16)
        guard dummy.count == 16 else { throw WinSCPINIError.invalid }
        let sealed = try seal(dummy, master: master, salt: salt)
        return hex(salt + dummy + sealed.suffix(10))
    }

    static func verify(_ verifier: String, master: String) throws {
        let bytes = try unhex(verifier)
        guard bytes.count == 42 else { throw WinSCPINIError.invalid }
        let sealed = try seal(Data(bytes[16..<32]), master: master, salt: Data(bytes.prefix(16)))
        guard equal(Data(bytes.suffix(10)), Data(sealed.suffix(10))) else { throw WinSCPINIError.wrongMaster }
    }

    static func encrypt(_ secret: String, master: String) throws -> String {
        guard !secret.isEmpty else { return "" }
        let bytes = Array(secret.utf8)
        guard bytes.count <= 999, !bytes.contains(0) else { throw WinSCPINIError.unsupported }
        let padding = ((bytes.count + 3) / 17 + 1) * 17 - 3 - bytes.count
        var plain: [UInt8] = []
        while plain.count < padding {
            for byte in try random(padding) where byte != 0 && !(48...57).contains(byte) {
                if plain.count < padding { plain.append(byte) }
            }
        }
        plain += [UInt8(48 + bytes.count % 10), UInt8(48 + bytes.count / 10 % 10), UInt8(48 + bytes.count / 100)] + bytes
        var previous = 31
        let scrambled = Data(plain.map { byte in
            previous = (previous + Int(byte)) % 255 + 1
            return permutation[previous]
        })
        return "A35D" + hex(try seal(scrambled, master: master, salt: random(16)))
    }

    static func decrypt(_ text: String, master: String, legacyKey: String) throws -> String? {
        guard !text.isEmpty else { return nil }
        if text.uppercased().hasPrefix("A35D") {
            let scrambled = try open(unhex(String(text.dropFirst(4))), master: master)
            var inverse = [Int](repeating: 0, count: 256)
            for (index, byte) in permutation.enumerated() { inverse[Int(byte)] = index }
            var previous = 31
            let plain = scrambled.map { byte -> UInt8 in
                var value = inverse[Int(byte)] - 1 - previous % 255
                if value <= 0 { value += 255 }
                previous = (previous + value) % 255 + 1
                return UInt8(value)
            }
            guard !scrambled.contains(0), let index = plain.firstIndex(where: { (48...57).contains($0) }),
                  index + 3 <= plain.count, plain[index..<index+3].allSatisfy({ (48...57).contains($0) }) else { throw WinSCPINIError.invalid }
            let length = Int(plain[index] - 48) + 10 * Int(plain[index+1] - 48) + 100 * Int(plain[index+2] - 48)
            guard plain.count == ((length + 3) / 17 + 1) * 17, index + 3 + length == plain.count,
                  let result = String(bytes: plain.suffix(length), encoding: .utf8) else { throw WinSCPINIError.invalid }
            return result
        }
        // Older records can coexist with a verified master-protected file.
        let encoded = try unhex(text).map { (~$0) ^ 0xA3 }
        var cursor = 0
        func next() throws -> UInt8 {
            guard cursor < encoded.count else { throw WinSCPINIError.invalid }
            defer { cursor += 1 }
            return encoded[cursor]
        }
        let flag = try next()
        var length = Int(flag)
        if flag == 255 {
            let version = try next()
            if version == 0 { length = Int(try next()) }
            else if version == 2 { length = Int(try next()) * 256 + Int(try next()) }
            else { throw WinSCPINIError.invalid }
        }
        let shift = try next()
        cursor += Int(shift)
        guard cursor + length <= encoded.count else { throw WinSCPINIError.invalid }
        var bytes = Array(encoded[cursor..<cursor+length])
        if flag == 255 {
            let prefix = Array(legacyKey.utf8)
            guard bytes.starts(with: prefix) else { throw WinSCPINIError.invalid }
            bytes.removeFirst(prefix.count)
        }
        guard let result = String(bytes: bytes, encoding: .utf8) else { throw WinSCPINIError.invalid }
        return result
    }
}
