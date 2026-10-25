// MacSCP-local adaptation: RSA file-key authentication using RFC 8332 only.
import CCryptoBoringSSL
import Crypto
import Foundation
import NIO
import NIOSSH

public protocol RSASHA2Variant {
    static var algorithmName: String { get }
    static var nid: Int32 { get }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8]
}

public enum RSASHA2_256: RSASHA2Variant {
    public static let algorithmName = "rsa-sha2-256"
    public static let nid = NID_sha256
    public static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA256.hash(data: Data(data))) }
}

public enum RSASHA2_512: RSASHA2Variant {
    public static let algorithmName = "rsa-sha2-512"
    public static let nid = NID_sha512
    public static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA512.hash(data: Data(data))) }
}

extension Insecure.RSA {
    private struct MacSCPSignature<Hash: RSASHA2Variant>: NIOSSHSignatureProtocol {
        static var signaturePrefix: String { Hash.algorithmName }
        let rawRepresentation: Data
        func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString(Array(rawRepresentation)) }
        static func read(from buffer: inout ByteBuffer) throws -> Self {
            guard let bytes = buffer.readSSHBuffer() else { throw CitadelError.signingError }
            return Self(rawRepresentation: Data(bytes.readableBytesView))
        }
    }

    public final class SHA2PublicKey<Hash: RSASHA2Variant>: NIOSSHPublicKeyProtocol {
        public static var publicKeyPrefix: String { "ssh-rsa" }
        public static var userAuthAlgorithmName: String { Hash.algorithmName }
        private let base: PublicKey
        fileprivate init(_ base: PublicKey) { self.base = base }
        public var rawRepresentation: Data { base.rawRepresentation }
        public func write(to buffer: inout ByteBuffer) -> Int { base.write(to: &buffer) }
        public static func read(from buffer: inout ByteBuffer) throws -> Self {
            Self(try PublicKey.read(from: &buffer))
        }
        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? MacSCPSignature<Hash>,
                  let rsa = CCryptoBoringSSL_RSA_new() else { return false }
            defer { CCryptoBoringSSL_RSA_free(rsa) }
            let modulus = CCryptoBoringSSL_BN_dup(base.modulus)
            let exponent = CCryptoBoringSSL_BN_dup(base.publicExponent)
            guard let modulus, let exponent else {
                CCryptoBoringSSL_BN_free(modulus)
                CCryptoBoringSSL_BN_free(exponent)
                return false
            }
            guard CCryptoBoringSSL_RSA_set0_key(rsa, modulus, exponent, nil) == 1 else {
                CCryptoBoringSSL_BN_free(modulus)
                CCryptoBoringSSL_BN_free(exponent)
                return false
            }
            let digest = Hash.digest(data)
            let bytes = Array(signature.rawRepresentation)
            return CCryptoBoringSSL_RSA_verify(Hash.nid, digest, digest.count, bytes, bytes.count, rsa) == 1
        }
    }

    private final class MacSCPPrivateKey<Hash: RSASHA2Variant>: NIOSSHPrivateKeyProtocol {
        static var keyPrefix: String { Hash.algorithmName }
        let base: PrivateKey
        init(_ base: PrivateKey) { self.base = base }
        var publicKey: NIOSSHPublicKeyProtocol { SHA2PublicKey<Hash>(base._publicKey) }
        func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            guard let rsa = CCryptoBoringSSL_RSA_new() else { throw CitadelError.signingError }
            defer { CCryptoBoringSSL_RSA_free(rsa) }
            let modulus = CCryptoBoringSSL_BN_dup(base._publicKey.modulus)
            let exponent = CCryptoBoringSSL_BN_dup(base._publicKey.publicExponent)
            let secret = CCryptoBoringSSL_BN_dup(base.privateExponent)
            guard let modulus, let exponent, let secret else {
                CCryptoBoringSSL_BN_free(modulus)
                CCryptoBoringSSL_BN_free(exponent)
                CCryptoBoringSSL_BN_clear_free(secret)
                throw CitadelError.signingError
            }
            guard CCryptoBoringSSL_RSA_set0_key(rsa, modulus, exponent, secret) == 1 else {
                CCryptoBoringSSL_BN_free(modulus)
                CCryptoBoringSSL_BN_free(exponent)
                CCryptoBoringSSL_BN_clear_free(secret)
                throw CitadelError.signingError
            }
            let digest = Hash.digest(data)
            var bytes = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_RSA_size(rsa)))
            var length = UInt32(bytes.count)
            guard CCryptoBoringSSL_RSA_sign(Hash.nid, digest, digest.count, &bytes, &length, rsa) == 1 else {
                throw CitadelError.signingError
            }
            return MacSCPSignature<Hash>(rawRepresentation: Data(bytes.prefix(Int(length))))
        }
    }

    fileprivate static func macSCPOffers(_ key: PrivateKey) -> [NIOSSHUserAuthenticationOffer.Offer] {
        [.privateKey(.init(privateKey: .init(custom: MacSCPPrivateKey<RSASHA2_512>(key)))),
         .privateKey(.init(privateKey: .init(custom: MacSCPPrivateKey<RSASHA2_256>(key))))]
    }
}

extension SSHAuthenticationMethod {
    /// MacSCP never signs file-key authentication with SHA-1.
    public static func rsaSHA2(username: String, privateKey: Insecure.RSA.PrivateKey) -> SSHAuthenticationMethod {
        Self(username: username, offers: Insecure.RSA.macSCPOffers(privateKey))
    }
}
