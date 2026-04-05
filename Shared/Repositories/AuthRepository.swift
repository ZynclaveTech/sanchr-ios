import Foundation
import GRPC

/// Protocol defining authentication operations against the backend.
protocol AuthRepositoryProtocol: AnyObject, Sendable {
    /// Requests an OTP for the given phone number.
    func requestOTP(phoneNumber: String, displayName: String?) async throws -> OTPRequestResult

    /// Verifies the OTP code and returns authentication tokens.
    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens

    /// Starts the staged registration flow by requesting an OTP.
    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult

    /// Refreshes an expired access token using the refresh token.
    func refreshToken(refreshToken: String) async throws -> AuthTokens

    /// Logs out and invalidates the current session on the server.
    func logout(accessToken: String) async throws

    /// Changes the current account password.
    func changePassword(currentPassword: String, newPassword: String) async throws

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
    let deviceId: String?
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

    func requestOTP(phoneNumber: String, displayName: String? = nil) async throws -> OTPRequestResult {
        SanchrLogger.auth.info("Requesting OTP for \(phoneNumber.prefix(4))****")
        let device = try makeDeviceInfo()

        // Call Register which handles both new and existing users.
        // New users are staged; existing users get an OTP generated for login.
        // Both paths return OK — the server handles user-enumeration prevention.
        do {
            var registerReq = Vync_Auth_RegisterRequest()
            registerReq.phoneNumber = phoneNumber
            registerReq.displayName = sanitizedDisplayName(displayName)
            registerReq.password = Self.otpBootstrapPassword()
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
        request.device = try makeDeviceInfo()

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
        if let deviceId = tokens.deviceId {
            try secureStorage.saveDeviceId(deviceId)
        }

        return tokens
    }

    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult {
        try await requestOTP(phoneNumber: phoneNumber, displayName: displayName)
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
        if let deviceId = tokens.deviceId {
            try secureStorage.saveDeviceId(deviceId)
        }

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

    func changePassword(currentPassword: String, newPassword: String) async throws {
        var request = Vync_Auth_ChangePasswordRequest()
        request.currentPassword = currentPassword
        request.newPassword = newPassword
        _ = try await authService.changePassword(request)
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
            expiresAt: decodeJWTExpiration(from: response.accessToken) ?? Date().addingTimeInterval(3600),
            userId: response.hasUser ? response.user.id : "",
            displayName: response.hasUser ? response.user.displayName : "",
            phoneNumber: response.hasUser ? response.user.phoneNumber : "",
            avatarURL: response.hasUser ? response.user.avatarURL : "",
            deviceId: response.deviceID == 0 ? nil : String(response.deviceID)
        )
    }

    private func makeDeviceInfo() throws -> Vync_Auth_DeviceInfo {
        var device = Vync_Auth_DeviceInfo()
        device.deviceName = "iPhone"
        device.platform = "ios"
        device.installationID = try secureStorage.readOrCreateInstallationId()
        device.supportsDeliveryAck = true
        return device
    }

    private func sanitizedDisplayName(_ displayName: String?) -> String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Sanchr User" : trimmed
    }

    private static func otpBootstrapPassword() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + "Aa1!"
    }

    private static func decodeJWTExpiration(from token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = json["exp"] as? TimeInterval
        else {
            return nil
        }

        return Date(timeIntervalSince1970: exp)
    }
}
