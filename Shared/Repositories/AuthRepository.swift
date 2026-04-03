import Foundation

/// Protocol defining authentication operations against the backend.
protocol AuthRepositoryProtocol: AnyObject, Sendable {
    /// Requests an OTP for the given phone number.
    func requestOTP(phoneNumber: String) async throws -> OTPRequestResult

    /// Verifies the OTP code and returns authentication tokens.
    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens

    /// Registers a new user account.
    func register(phoneNumber: String, displayName: String, identityPublicKey: Data) async throws
        -> AuthTokens

    /// Refreshes an expired access token using the refresh token.
    func refreshToken(refreshToken: String) async throws -> AuthTokens

    /// Logs out and invalidates the current session on the server.
    func logout(accessToken: String) async throws

    /// Uploads pre-key bundle to the server for Signal Protocol.
    func uploadPreKeyBundle(
        identityKey: Data,
        signedPreKey: Data,
        signedPreKeySignature: Data,
        oneTimePreKeys: [Data]
    ) async throws
}

// MARK: - Supporting Types

struct OTPRequestResult: Sendable {
    let requestId: String
    let expiresInSeconds: Int
    let phoneNumber: String
}

struct AuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userId: String
}

// MARK: - Implementation Shell

final class AuthRepositoryImpl: AuthRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let secureStorage: SecureStorageProtocol

    init(grpcClient: GRPCClientProtocol, secureStorage: SecureStorageProtocol) {
        self.grpcClient = grpcClient
        self.secureStorage = secureStorage
    }

    func requestOTP(phoneNumber: String) async throws -> OTPRequestResult {
        // TODO: Call gRPC auth.RequestOTP
        SanchrLogger.auth.info("Requesting OTP for \(phoneNumber.prefix(4))****")
        throw AppError.serverUnreachable
    }

    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens
    {
        // TODO: Call gRPC auth.VerifyOTP
        throw AppError.serverUnreachable
    }

    func register(phoneNumber: String, displayName: String, identityPublicKey: Data) async throws
        -> AuthTokens
    {
        // TODO: Call gRPC auth.Register
        throw AppError.serverUnreachable
    }

    func refreshToken(refreshToken: String) async throws -> AuthTokens {
        // TODO: Call gRPC auth.RefreshToken
        throw AppError.serverUnreachable
    }

    func logout(accessToken: String) async throws {
        // TODO: Call gRPC auth.Logout
    }

    func uploadPreKeyBundle(
        identityKey: Data,
        signedPreKey: Data,
        signedPreKeySignature: Data,
        oneTimePreKeys: [Data]
    ) async throws {
        // TODO: Call gRPC auth.UploadPreKeyBundle
    }
}
