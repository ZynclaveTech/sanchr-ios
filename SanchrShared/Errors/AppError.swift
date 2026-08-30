import Foundation

/// Typed error hierarchy for the Sanchr application.
/// Each case maps to a user-facing message and a recovery strategy.
public enum AppError: LocalizedError, Equatable {
    // MARK: - Network

    case networkUnavailable
    case serverUnreachable
    case requestTimeout
    case grpcError(code: Int, message: String)

    // MARK: - Auth

    case invalidCredentials
    case sessionExpired
    case otpExpired
    case otpInvalid
    case accountLocked
    case registrationLockPinRequired
    case registrationFailed(reason: String)

    // MARK: - Encryption

    case encryptionFailed(reason: String)
    case decryptionFailed(reason: String)
    case keyGenerationFailed
    case sessionNotEstablished
    case untrustedIdentity

    // MARK: - Storage

    case databaseError(reason: String)
    case localDataUnavailable(reason: String)
    case keychainReadFailed
    case keychainWriteFailed
    case insufficientStorage
    case recoveryKeyUnavailable
    case biometricAuthenticationFailed(reason: String)
    case backupUnavailable
    case backupFailed(reason: String)
    case backupIntegrityCheckFailed(reason: String)

    // MARK: - Media

    case mediaCaptureFailed
    case mediaCompressionFailed
    case mediaUploadFailed
    case mediaDownloadFailed
    case unsupportedMediaType

    // MARK: - Calls

    case callConnectionFailed
    case callPermissionDenied
    case callAlreadyInProgress

    // MARK: - Contacts

    /// Address-book access was refused, so discovery has nothing to match.
    case contactsPermissionDenied

    // MARK: - Feature Gates

    /// Thrown when a caller attempts to use a feature that this build
    /// configuration has disabled. `feature` is a snake_case identifier
    /// suitable for log lines and analytics (e.g. `"video_call"`).
    case featureDisabled(feature: String)

    // MARK: - General

    case unknown(underlying: String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "No internet connection. Please check your network settings."
        case .serverUnreachable:
            return "Unable to reach the server. Please try again later."
        case .requestTimeout:
            return "The request timed out. Please try again."
        case .grpcError(_, let message):
            return message
        case .invalidCredentials:
            return "Invalid phone number or verification code."
        case .sessionExpired:
            return "Your session has expired. Please log in again."
        case .otpExpired:
            return "The verification code has expired. Please request a new one."
        case .otpInvalid:
            return "Invalid verification code. Please try again."
        case .accountLocked:
            return "Your account has been locked. Please contact support."
        case .registrationLockPinRequired:
            return "A registration lock PIN is required to verify this account."
        case .registrationFailed(let reason):
            return "Registration failed: \(reason)"
        case .encryptionFailed(let reason):
            return "Encryption error: \(reason)"
        case .decryptionFailed(let reason):
            return "Unable to decrypt message: \(reason)"
        case .keyGenerationFailed:
            return "Failed to generate encryption keys."
        case .sessionNotEstablished:
            return "Secure session not yet established with this contact."
        case .untrustedIdentity:
            return "The identity of this contact has changed. Please verify."
        case .databaseError(let reason):
            return "Database error: \(reason)"
        case .localDataUnavailable(let reason):
            return reason
        case .keychainReadFailed:
            return "Unable to read from secure storage."
        case .keychainWriteFailed:
            return "Unable to save to secure storage."
        case .insufficientStorage:
            return "Insufficient storage space on device."
        case .recoveryKeyUnavailable:
            return "No recovery key is available on this device."
        case .biometricAuthenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .backupUnavailable:
            return "No encrypted backup is available for this account."
        case .backupFailed(let reason):
            return "Backup failed: \(reason)"
        case .backupIntegrityCheckFailed(let reason):
            return "Backup verification failed: \(reason)"
        case .mediaCaptureFailed:
            return "Failed to capture media."
        case .mediaCompressionFailed:
            return "Failed to compress media for sending."
        case .mediaUploadFailed:
            return "Failed to upload media. Please try again."
        case .mediaDownloadFailed:
            return "Failed to download media."
        case .unsupportedMediaType:
            return "This media type is not supported."
        case .callConnectionFailed:
            return "Unable to connect the call. Please try again."
        case .callPermissionDenied:
            // Names the way out. Once permission is denied the app cannot ask
            // again, so a message that only states the problem leaves the
            // person stuck with no idea the fix is elsewhere.
            return "Microphone permission is required for calls. You can turn it on in Settings."
        case .contactsPermissionDenied:
            // Names the way out. Once refused, the app cannot ask again, so a
            // message that only states the problem leaves the person stuck
            // looking at an empty list with no idea why.
            return "Sanchr needs access to your contacts to find people you know. "
                + "You can turn it on in Settings."
        case .callAlreadyInProgress:
            return "A call is already in progress."
        case .featureDisabled:
            return "This feature is not available in this build."
        case .unknown(let underlying):
            return "An unexpected error occurred: \(underlying)"
        }
    }

    /// Whether this error is recoverable by retrying.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .serverUnreachable, .requestTimeout,
            .mediaUploadFailed, .mediaDownloadFailed, .callConnectionFailed:
            return true
        default:
            return false
        }
    }
}
