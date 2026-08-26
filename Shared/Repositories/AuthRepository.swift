import Foundation
import GRPC
import SanchrShared

/// Protocol defining authentication operations against the backend.
protocol AuthRepositoryProtocol: AnyObject, Sendable {
    /// Requests an OTP for the given phone number.
    func requestOTP(phoneNumber: String, displayName: String?) async throws -> OTPRequestResult

    /// Verifies the OTP code and returns authentication tokens.
    func verifyOTP(phoneNumber: String, code: String, requestId: String, registrationLockPin: String?) async throws -> AuthTokens

    /// Starts the staged registration flow by requesting an OTP.
    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult

    /// Refreshes an expired access token using the refresh token.
    func refreshToken(refreshToken: String) async throws -> AuthTokens

    /// Logs out and invalidates the current session on the server.
    func logout(accessToken: String) async throws

    /// Permanently deletes the authenticated user's account on the server.
    func deleteAccount() async throws

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

    /// Default OTP TTL fallback (seconds) used when the server returns 0.
    /// Mirrors the previous hardcoded value before the RequestOtp RPC existed.
    private static let defaultOtpExpirySeconds: Int = 300

    init(grpcClient: GRPCClientProtocol, secureStorage: SecureStorageProtocol) {
        self.grpcClient = grpcClient
        self.secureStorage = secureStorage
    }

    private var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol {
        grpcClient.authService
    }

    /// Requests an OTP via `AuthService.RequestOtp` (see
    /// `backend/crates/sanchr-core/src/auth/handlers.rs::handle_request_otp`,
    /// introduced in commit `bdfb5a7`). The server handles both new and existing
    /// users uniformly: new phones are staged in `pending_registrations` with a
    /// "Sanchr User" placeholder display name; existing users get an OTP issued
    /// for login. User-enumeration prevention is server-side.
    ///
    /// The `displayName` parameter is retained for source compatibility with
    /// callers that still pass it (e.g. `register(phoneNumber:displayName:)`),
    /// but is intentionally ignored on the wire — the new RPC is phone-only and
    /// the display name is collected post-OTP via `OnboardingNameStepView`.
    func requestOTP(phoneNumber: String, displayName: String? = nil) async throws -> OTPRequestResult {
        SanchrLogger.auth.info("Requesting OTP for \(phoneNumber.prefix(4))****")
        let device = try makeDeviceInfo()

        let response: Sanchr_Auth_RequestOtpResponse
        do {
            var req = Sanchr_Auth_RequestOtpRequest()
            req.phoneNumber = phoneNumber
            req.device = device
            response = try await authService.requestOtp(req)
            SanchrLogger.auth.info("RequestOtp succeeded (existingUser=\(response.existingUser))")
        } catch {
            SanchrLogger.auth.error("requestOTP failed: \(Self.detailedError(error))")
            throw error
        }

        // Clamp Int64 → Int and fall back to the historical 300s default if the
        // server returned 0 (e.g. older server build pre-Phase 0).
        let expirySeconds: Int
        if response.expiresInSeconds > 0 {
            expirySeconds = Int(min(Int64(Int.max), response.expiresInSeconds))
        } else {
            expirySeconds = Self.defaultOtpExpirySeconds
        }

        return OTPRequestResult(
            requestId: phoneNumber,
            expiresInSeconds: expirySeconds,
            phoneNumber: phoneNumber
        )
    }

    func verifyOTP(phoneNumber: String, code: String, requestId: String, registrationLockPin: String? = nil) async throws -> AuthTokens {
        SanchrLogger.auth.info("Verifying OTP for \(phoneNumber.prefix(4))****")

        var request = Sanchr_Auth_VerifyOTPRequest()
        request.phoneNumber = phoneNumber
        request.otpCode = code
        request.device = try makeDeviceInfo()
        if let pin = registrationLockPin, !pin.isEmpty {
            request.registrationLockPin = pin
        }

        let response: Sanchr_Auth_AuthResponse
        do {
            response = try await authService.verifyOTP(request)
        } catch let error as GRPCStatus where error.message?.contains("registration_lock_pin_required") == true {
            SanchrLogger.auth.info("Server requires registration lock PIN")
            throw AppError.registrationLockPinRequired
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

    /// Account-creation entry point. Delegates to `requestOTP` because the
    /// backend `RequestOtp` RPC handles both new and existing users uniformly,
    /// and the user's chosen display name is collected post-OTP in
    /// `OnboardingNameStepView` (filtered via `hasCompletedProfileBasics` in
    /// `SanchrApp.swift`). `displayName` is therefore ignored on the wire here.
    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult {
        try await requestOTP(phoneNumber: phoneNumber, displayName: displayName)
    }

    func refreshToken(refreshToken: String) async throws -> AuthTokens {
        SanchrLogger.auth.info("Refreshing token")

        var request = Sanchr_Auth_RefreshTokenRequest()
        request.refreshToken = refreshToken

        let response: Sanchr_Auth_AuthResponse
        do {
            response = try await authService.refreshToken(request)
        } catch {
            SanchrLogger.auth.error("refreshToken failed: \(Self.detailedError(error))")
            throw error
        }

        let tokens = Self.mapTokens(response)
        try secureStorage.saveAccessToken(tokens.accessToken)
        // Only overwrite the stored refresh token if the server returned a non-empty one.
        // Some servers reuse the existing refresh token (no rotation); persisting an empty
        // string would clobber the valid token in Keychain and cause an immediate logout
        // on the next refresh cycle.
        if !tokens.refreshToken.isEmpty {
            try secureStorage.saveRefreshToken(tokens.refreshToken)
        }
        if let deviceId = tokens.deviceId {
            try secureStorage.saveDeviceId(deviceId)
        }

        return tokens
    }

    func logout(accessToken: String) async throws {
        SanchrLogger.auth.info("Logging out")

        // Retrieve the refresh token to invalidate on the server
        guard let refreshToken = try secureStorage.readRefreshToken() else { return }

        var request = Sanchr_Auth_LogoutRequest()
        request.refreshToken = refreshToken

        _ = try await authService.logout(request)
    }

    func deleteAccount() async throws {
        SanchrLogger.auth.warning("Submitting account deletion request")
        let request = Sanchr_Auth_DeleteAccountRequest()
        do {
            let response = try await authService.deleteAccount(request)
            guard response.success else {
                SanchrLogger.auth.error("deleteAccount returned success=false")
                throw AppError.unknown(underlying: "Account deletion was not confirmed by the server.")
            }
            SanchrLogger.auth.info("Account deletion confirmed by server")
        } catch {
            SanchrLogger.auth.error("deleteAccount failed: \(Self.detailedError(error))")
            throw error
        }
    }

    // MARK: - Mapping

    // MARK: - Diagnostics

    static func detailedError(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            return "gRPC \(status.code) (\(status.code.rawValue)): \(status.message ?? "no message")"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    private static func mapTokens(_ response: Sanchr_Auth_AuthResponse) -> AuthTokens {
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

    private func makeDeviceInfo() throws -> Sanchr_Auth_DeviceInfo {
        var device = Sanchr_Auth_DeviceInfo()
        device.deviceName = "iPhone"
        device.platform = "ios"
        device.installationID = try secureStorage.readOrCreateInstallationId()
        device.supportsDeliveryAck = true
        return device
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
