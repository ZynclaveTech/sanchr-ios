import CryptoKit
import Foundation
import NIOSSL

/// Pins the TLS connection to a known set of public keys.
///
/// Without this, the app trusts any certificate a system-trusted CA will sign for
/// the host — which is exactly the position a rogue or compelled CA exploits. That
/// matters more here than in a typical app, because the pinned channel is the one
/// that distributes pre-key bundles: an attacker who can substitute a certificate
/// can substitute identity keys.
///
/// Two deliberate choices:
///
/// **Public keys, not certificates.** The previous implementation hashed the whole
/// leaf DER. The API is served through cert-manager with Let's Encrypt, which
/// renews roughly every 60 days, so a leaf-certificate pin would have bricked
/// every installed client on the first renewal. A `SubjectPublicKeyInfo` pin
/// survives renewal as long as the key is reused, which is cert-manager's default.
///
/// **Any certificate in the chain may match.** Pinning only the leaf makes key
/// rotation a coordinated app release. Allowing a match anywhere in the presented
/// chain means an intermediate or root can be pinned as a backup, so a leaf key
/// rotation degrades to "still pinned, less tightly" instead of "all clients
/// offline". Ship at least two pins for this reason.
public enum CertificatePinning {

    public enum PinningError: LocalizedError, Equatable {
        case emptyChain
        case noPinMatched(presented: [String])

        public var errorDescription: String? {
            switch self {
            case .emptyChain:
                return "TLS peer presented no certificates"
            case .noPinMatched:
                // Deliberately vague to the caller; specifics go to the log.
                return "Server certificate is not trusted for this app"
            }
        }
    }

    /// Base64 SHA-256 of a certificate's `SubjectPublicKeyInfo`.
    ///
    /// Matches the value produced by:
    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`
    public static func spkiPin(for certificate: NIOSSLCertificate) throws -> String {
        let spki = try certificate.extractPublicKey().toSPKIBytes()
        return Data(SHA256.hash(data: Data(spki))).base64EncodedString()
    }

    /// Succeeds when any certificate in `chain` has an SPKI pin present in `pins`.
    ///
    /// An empty `pins` set means pinning is not configured; callers decide whether
    /// that is acceptable rather than having this silently pass.
    public static func validate(
        chain: [NIOSSLCertificate],
        against pins: Set<String>
    ) throws {
        guard !chain.isEmpty else { throw PinningError.emptyChain }

        var presented: [String] = []
        for certificate in chain {
            // A certificate whose key cannot be read is skipped rather than
            // failing the whole chain: an unreadable intermediate must not be
            // able to block an otherwise valid leaf pin.
            guard let pin = try? spkiPin(for: certificate) else { continue }
            presented.append(pin)
            if pins.contains(pin) { return }
        }

        SanchrLogger.security.critical(
            "Certificate pinning REJECTED connection. Presented SPKI pins: \(presented.joined(separator: ", "))"
        )
        throw PinningError.noPinMatched(presented: presented)
    }
}
