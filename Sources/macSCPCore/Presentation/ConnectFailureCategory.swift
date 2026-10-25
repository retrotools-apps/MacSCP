import Foundation

/// Payload-free primary messages, classified from error types, never by parsing
/// server text or localized sentences.
public enum ConnectFailureCategory: String, CaseIterable, Sendable {
    case authentication, jumpAuthentication, network, timeout, nameResolution
    case tls, hostKey, key, keychain, unknown

    public static func classify(_ error: any Error) -> Self {
        if let error = error as? RemoteFSError, error == .jumpAuthenticationFailed { return .jumpAuthentication }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return .timeout
            case .cannotFindHost, .dnsLookupFailed: return .nameResolution
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet: return .network
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired: return .tls
            default: break
            }
        }
        switch DialSupport.failureKind(for: error) {
        case .authenticationFailed, .agentRefusedEveryIdentity: return .authentication
        case .connectionFailed: return .network
        case .hostKeyMismatch, .hostKeyNotAccepted: return .hostKey
        case .keyFileNotFound, .keyPassphraseRequired, .keyPassphraseRejected,
             .keyUnparsable, .keyTypeNotLoadable, .keyPEMNotReadable,
             .managedKeyStoreUnreadable, .agentUnavailable, .agentHasNoIdentities,
             .agentHasNoUsableIdentity, .agentMisbehaved: return .key
        case .keychainUnreadable: return .keychain
        default: return .unknown
        }
    }
}
