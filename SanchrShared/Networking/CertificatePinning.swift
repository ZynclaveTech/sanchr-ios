import CryptoKit
import Foundation
import NIOSSL

/// Validates TLS certificates against pinned hashes to prevent MITM attacks.
final class CertificatePinningValidator {
    enum Error: LocalizedError {
        case noCertificateReceived
        case certificateHashMismatch(expected: String, received: String)
        case noPinConfigured

        var errorDescription: String? {
            switch self {
            case .noCertificateReceived:
                return "No certificate received from server"
            case .certificateHashMismatch(let expected, let received):
                return "Certificate hash mismatch: expected \(expected), got \(received)"
            case .noPinConfigured:
                return "Certificate pinning not configured for this host"
            }
        }
    }

    /// Validates a certificate against an expected SHA-256 hash
    static func validateCertificatePin(
        certificate: SecCertificate,
        expectedHash: String
    ) throws {
        let certData = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: certData)
        let receivedHash = Data(digest).base64EncodedString()

        guard receivedHash == expectedHash else {
            SanchrLogger.security.critical(
                "CertificatePinning FAILED: expected \(expectedHash), received \(receivedHash)"
            )
            throw Error.certificateHashMismatch(expected: expectedHash, received: receivedHash)
        }

        SanchrLogger.security.debug("CertificatePinning validated successfully")
    }
}
