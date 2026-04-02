import Foundation

/// Typed error hierarchy for the Sanchr application.
/// Each case maps to a user-facing message and a recovery strategy.
enum AppError: LocalizedError, Equatable {
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
    case registrationFailed(reason: String)

    // MARK: - Encryption

    case encryptionFailed(reason: String)
    case decryptionFailed(reason: String)
    case keyGenerationFailed
    case sessionNotEstablished
    case untrustedIdentity

    // MARK: - Storage

    case databaseError(reason: String)
    case keychainReadFailed
    case keychainWriteFailed
    case insufficientStorage

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

    // MARK: - General

    case unknown(underlying: String)

    // MARK: - LocalizedError

    var errorDescription: String? {
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
        case .keychainReadFailed:
            return "Unable to read from secure storage."
        case .keychainWriteFailed:
            return "Unable to save to secure storage."
        case .insufficientStorage:
            return "Insufficient storage space on device."
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
            return "Microphone permission is required for calls."
        case .callAlreadyInProgress:
            return "A call is already in progress."
        case .unknown(let underlying):
            return "An unexpected error occurred: \(underlying)"
        }
    }

    /// Whether this error is recoverable by retrying.
    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .serverUnreachable, .requestTimeout,
             .mediaUploadFailed, .mediaDownloadFailed, .callConnectionFailed:
            return true
        default:
            return false
        }
    }
}
