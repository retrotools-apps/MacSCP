// MacSCP-local adaptation: read encrypted OpenSSH ECDSA keys using Citadel's
// existing container/KDF reader. No new export or key-type diagnostic API.
import Crypto
import Foundation
import NIO

private enum MacSCPECDSAEncoding {
    static func readPoint(_ buffer: inout ByteBuffer, curve: String, width: Int) throws -> Data {
        guard buffer.readSSHString() == curve,
              let bytes = buffer.readSSHBuffer(),
              bytes.readableBytes == 1 + 2 * width,
              bytes.readableBytesView.first == 4 else {
            throw InvalidOpenSSHKey.invalidLayout
        }
        return Data(bytes.readableBytesView)
    }

    static func writePoint(_ point: Data, curve: String, to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(Array(curve.utf8)) + buffer.writeSSHString(Array(point))
    }
}

protocol MacSCPECDSAPrivateKey: OpenSSHPrivateKey {
    static var curve: String { get }
    static var width: Int { get }
    init(rawRepresentation: Data) throws
    var rawRepresentation: Data { get }
    var publicPoint: Data { get }
}

extension MacSCPECDSAPrivateKey {
    static var publicKeyPrefix: String { "ecdsa-sha2-\(curve)" }
    static var privateKeyPrefix: String { publicKeyPrefix }
    static var keyType: OpenSSH.KeyType { OpenSSH.KeyType(rawValue: publicKeyPrefix)! }

    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        let point = try MacSCPECDSAEncoding.readPoint(&buffer, curve: curve, width: width)
        guard let encoded = buffer.readSSHBuffer(),
              let first = encoded.readableBytesView.first, first & 0x80 == 0 else {
            throw InvalidOpenSSHKey.invalidLayout
        }
        let magnitude = encoded.readableBytesView.drop(while: { $0 == 0 })
        guard magnitude.count <= width else { throw InvalidOpenSSHKey.invalidLayout }
        let scalar = Data(repeating: 0, count: width - magnitude.count) + Data(magnitude)
        let key = try Self(rawRepresentation: scalar)
        guard key.publicPoint == point else { throw InvalidOpenSSHKey.invalidPublicKeyInPrivateKey }
        return key
    }

    // Required by Citadel's existing ByteBufferConvertible contract.
    func write(to buffer: inout ByteBuffer) -> Int {
        var scalar = Array(rawRepresentation.drop(while: { $0 == 0 }))
        if let first = scalar.first, first & 0x80 != 0 { scalar.insert(0, at: 0) }
        return MacSCPECDSAEncoding.writePoint(publicPoint, curve: Self.curve, to: &buffer)
            + buffer.writeSSHString(scalar)
    }
}

extension P256.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try Self(x963Representation: MacSCPECDSAEncoding.readPoint(&buffer, curve: "nistp256", width: 32))
    }
    func write(to buffer: inout ByteBuffer) -> Int {
        MacSCPECDSAEncoding.writePoint(x963Representation, curve: "nistp256", to: &buffer)
    }
}

extension P384.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try Self(x963Representation: MacSCPECDSAEncoding.readPoint(&buffer, curve: "nistp384", width: 48))
    }
    func write(to buffer: inout ByteBuffer) -> Int {
        MacSCPECDSAEncoding.writePoint(x963Representation, curve: "nistp384", to: &buffer)
    }
}

extension P521.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try Self(x963Representation: MacSCPECDSAEncoding.readPoint(&buffer, curve: "nistp521", width: 66))
    }
    func write(to buffer: inout ByteBuffer) -> Int {
        MacSCPECDSAEncoding.writePoint(x963Representation, curve: "nistp521", to: &buffer)
    }
}

extension P256.Signing.PrivateKey: MacSCPECDSAPrivateKey {
    typealias PublicKey = P256.Signing.PublicKey
    static var curve: String { "nistp256" }
    static var width: Int { 32 }
    var publicPoint: Data { publicKey.x963Representation }
    public init(sshEcdsa key: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<Self>(string: key, decryptionKey: decryptionKey).privateKey
    }
}

extension P384.Signing.PrivateKey: MacSCPECDSAPrivateKey {
    typealias PublicKey = P384.Signing.PublicKey
    static var curve: String { "nistp384" }
    static var width: Int { 48 }
    var publicPoint: Data { publicKey.x963Representation }
    public init(sshEcdsa key: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<Self>(string: key, decryptionKey: decryptionKey).privateKey
    }
}

extension P521.Signing.PrivateKey: MacSCPECDSAPrivateKey {
    typealias PublicKey = P521.Signing.PublicKey
    static var curve: String { "nistp521" }
    static var width: Int { 66 }
    var publicPoint: Data { publicKey.x963Representation }
    public init(sshEcdsa key: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<Self>(string: key, decryptionKey: decryptionKey).privateKey
    }
}
