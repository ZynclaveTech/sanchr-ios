import Foundation
import GRPC

/// One place that turns any failure into a sentence a person can act on.
///
/// `GRPCStatus` is not a `LocalizedError`, so every screen that showed
/// `error.localizedDescription` printed "The operation couldn't be
/// completed. (GRPC.GRPCStatus error 14.)". The conformance below fixes
/// that everywhere at once; `message(for:)` is the explicit entry point for
/// view models, and covers the network errors that arrive as `URLError`.
public enum UserFacingError {
    public static let generic = "Something went wrong. Try again in a moment."
    public static let offline = "Can't reach Sanchr. Check your connection and try again."
    public static let timeout = "That took too long. Check your connection and try again."

    public static func message(for error: Error) -> String {
        if let status = error as? GRPCStatus {
            return message(forGRPC: status.code)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return offline
            case .timedOut:
                return timeout
            default:
                return generic
            }
        }
        if error is CancellationError {
            return "Cancelled."
        }
        if let appError = error as? AppError, let description = appError.errorDescription, !description.isEmpty {
            return description
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return generic
    }

    /// Copy per gRPC status, written for what the app's calls mean by them.
    public static func message(forGRPC code: GRPCStatus.Code) -> String {
        switch code {
        case .ok: return ""
        case .cancelled: return "Cancelled."
        case .unavailable, .aborted: return offline
        case .deadlineExceeded: return timeout
        case .unauthenticated: return "Your session needs to sign in again."
        case .permissionDenied: return "You don't have permission to do that."
        case .resourceExhausted: return "Too many attempts. Wait a few minutes and try again."
        case .notFound: return "That wasn't found. It may have been removed."
        case .alreadyExists: return "That already exists."
        case .invalidArgument, .failedPrecondition, .outOfRange: return "Something about that request isn't right. Check it and try again."
        case .unimplemented: return "That isn't available in this version of Sanchr yet."
        case .internalError, .unknown, .dataLoss: return "Sanchr had a problem on its side. Try again in a moment."
        default: return generic  // `Code` is a struct with static members, not an enum
        }
    }
}

/// The library type carries only a code and an optional message; give it a
/// description people can read, so no screen ever shows the type name.
extension GRPCStatus: @retroactive LocalizedError {
    public var errorDescription: String? {
        UserFacingError.message(forGRPC: code)
    }
}
