import Foundation
import GRPC

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
    let displayName: String
    let phoneNumber: String
    let avatarURL: String
}

// MARK: - Implementation

final class AuthRepositoryImpl: AuthRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let secureStorage: SecureStorageProtocol

    init(grpcClient: GRPCClientProtocol, secureStorage: SecureStorageProtocol) {
        self.grpcClient = grpcClient
        self.secureStorage = secureStorage
    }

    private var authService: Vync_Auth_AuthServiceAsyncClientProtocol {
        grpcClient.authService
    }

    func requestOTP(phoneNumber: String) async throws -> OTPRequestResult {
        SanchrLogger.auth.info("Requesting OTP for \(phoneNumber.prefix(4))****")

        var device = Vync_Auth_DeviceInfo()
        device.deviceName = "iPhone"
        device.platform = "ios"

        // Call Register which handles both new and existing users.
        // New users get created; existing users get an OTP generated for login.
        // Both paths return OK — the server handles user-enumeration prevention.
        do {
            var registerReq = Vync_Auth_RegisterRequest()
            registerReq.phoneNumber = phoneNumber
            registerReq.displayName = "Sanchr User"
            registerReq.password = "temp_otp_flow"
            registerReq.device = device
            _ = try await authService.register(registerReq)
            SanchrLogger.auth.info("Register/OTP request succeeded")
        } catch {
            SanchrLogger.auth.error("requestOTP failed: \(Self.detailedError(error))")
            throw error
        }

        return OTPRequestResult(
            requestId: phoneNumber,
            expiresInSeconds: 300,
            phoneNumber: phoneNumber
        )
    }

    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens {
        SanchrLogger.auth.info("Verifying OTP for \(phoneNumber.prefix(4))****")

        var request = Vync_Auth_VerifyOTPRequest()
        request.phoneNumber = phoneNumber
        request.otpCode = code
        var device = Vync_Auth_DeviceInfo()
        device.deviceName = "iPhone"
        device.platform = "ios"
        request.device = device

        let response: Vync_Auth_AuthResponse
        do {
            response = try await authService.verifyOTP(request)
        } catch {
            SanchrLogger.auth.error("verifyOTP failed: \(Self.detailedError(error))")
            throw error
        }

        let tokens = Self.mapTokens(response)
        SanchrLogger.auth.info("OTP verified, userId=\(tokens.userId.prefix(8))..., hasToken=\(!tokens.accessToken.isEmpty)")

        // Persist tokens
        try secureStorage.saveAccessToken(tokens.accessToken)
        try secureStorage.saveRefreshToken(tokens.refreshToken)
        if response.deviceID != 0 {
            try secureStorage.saveDeviceId(String(response.deviceID))
        }

        return tokens
    }

    func register(phoneNumber: String, displayName: String, identityPublicKey: Data) async throws
        -> AuthTokens
    {
        SanchrLogger.auth.info("Registering \(phoneNumber.prefix(4))****")

        var request = Vync_Auth_RegisterRequest()
        request.phoneNumber = phoneNumber
        request.displayName = displayName
        var device = Vync_Auth_DeviceInfo()
        device.deviceName = "iPhone"
        device.platform = "ios"
        request.device = device

        let response = try await authService.register(request)
        let tokens = Self.mapTokens(response)

        try secureStorage.saveAccessToken(tokens.accessToken)
        try secureStorage.saveRefreshToken(tokens.refreshToken)
        if response.deviceID != 0 {
            try secureStorage.saveDeviceId(String(response.deviceID))
        }

        return tokens
    }

    func refreshToken(refreshToken: String) async throws -> AuthTokens {
        SanchrLogger.auth.info("Refreshing token")

        var request = Vync_Auth_RefreshTokenRequest()
        request.refreshToken = refreshToken

        let response: Vync_Auth_AuthResponse
        do {
            response = try await authService.refreshToken(request)
        } catch {
            SanchrLogger.auth.error("refreshToken failed: \(Self.detailedError(error))")
            throw error
        }

        let tokens = Self.mapTokens(response)
        try secureStorage.saveAccessToken(tokens.accessToken)
        try secureStorage.saveRefreshToken(tokens.refreshToken)

        return tokens
    }

    func logout(accessToken: String) async throws {
        SanchrLogger.auth.info("Logging out")

        // Retrieve the refresh token to invalidate on the server
        guard let refreshToken = try secureStorage.readRefreshToken() else { return }

        var request = Vync_Auth_LogoutRequest()
        request.refreshToken = refreshToken

        _ = try await authService.logout(request)
    }

    func uploadPreKeyBundle(
        identityKey: Data,
        signedPreKey: Data,
        signedPreKeySignature: Data,
        oneTimePreKeys: [Data]
    ) async throws {
        SanchrLogger.auth.info("Uploading pre-key bundle")

        var bundle = Vync_Keys_KeyBundle()
        bundle.identityPublicKey = identityKey

        var spk = Vync_Keys_SignedPreKey()
        spk.publicKey = signedPreKey
        spk.signature = signedPreKeySignature
        bundle.signedPreKey = spk

        bundle.oneTimePreKeys = oneTimePreKeys.enumerated().map { index, keyData in
            var otpk = Vync_Keys_OneTimePreKey()
            otpk.keyID = Int32(index)
            otpk.publicKey = keyData
            return otpk
        }

        _ = try await grpcClient.keyService.uploadKeyBundle(bundle)
    }

    // MARK: - Mapping

    // MARK: - Diagnostics

    static func detailedError(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            return "gRPC \(status.code) (\(status.code.rawValue)): \(status.message ?? "no message")"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    private static func mapTokens(_ response: Vync_Auth_AuthResponse) -> AuthTokens {
        AuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(3600),
            userId: response.hasUser ? response.user.id : "",
            displayName: response.hasUser ? response.user.displayName : "",
            phoneNumber: response.hasUser ? response.user.phoneNumber : "",
            avatarURL: response.hasUser ? response.user.avatarURL : ""
        )
    }
}
