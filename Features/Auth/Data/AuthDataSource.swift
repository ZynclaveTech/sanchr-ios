import Foundation

/// Data source for authentication gRPC service calls.
/// Translates between domain models and protobuf messages.
final class AuthDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let keychainService: KeychainServiceProtocol

    /// Device info populated once on init to avoid repeated lookups.
    private let deviceInfo: Vync_Auth_DeviceInfo

    /// Convenience accessor for the auth async client from the gRPC manager.
    private var authClient: Vync_Auth_AuthServiceAsyncClientProtocol {
        grpcClient.authService
    }

    init(grpcClient: GRPCClientProtocol, keychainService: KeychainServiceProtocol) {
        self.grpcClient = grpcClient
        self.keychainService = keychainService
        var device = Vync_Auth_DeviceInfo()
        device.deviceName = "iPhone"
        device.platform = "ios"
        self.deviceInfo = device
    }

    // MARK: - Registration

    /// Registers a new user and returns auth tokens.
    func register(
        phoneNumber: String, displayName: String, password: String = "", email: String = ""
    ) async throws -> AuthTokens {
        var request = Vync_Auth_RegisterRequest()
        request.phoneNumber = phoneNumber
        request.displayName = displayName
        request.password = password
        request.email = email
        request.device = deviceInfo

        SanchrLogger.auth.info("AuthDataSource: register for \(phoneNumber.prefix(4))****")
        let response = try await authClient.register(request)
        try storeTokens(from: response)
        return Self.mapToAuthTokens(response)
    }

    // MARK: - OTP Verification

    /// Verifies the OTP code and returns auth tokens on success.
    func verifyOTP(phoneNumber: String, otpCode: String) async throws -> AuthTokens {
        var request = Vync_Auth_VerifyOTPRequest()
        request.phoneNumber = phoneNumber
        request.otpCode = otpCode
        request.device = deviceInfo

        SanchrLogger.auth.info("AuthDataSource: verifyOTP")
        let response = try await authClient.verifyOTP(request)
        try storeTokens(from: response)
        return Self.mapToAuthTokens(response)
    }

    // MARK: - Login

    /// Authenticates with phone number and password. Returns auth tokens.
    func login(phoneNumber: String, password: String) async throws -> AuthTokens {
        var request = Vync_Auth_LoginRequest()
        request.phoneNumber = phoneNumber
        request.password = password
        request.device = deviceInfo

        SanchrLogger.auth.info("AuthDataSource: login for \(phoneNumber.prefix(4))****")
        let response = try await authClient.login(request)
        try storeTokens(from: response)
        return Self.mapToAuthTokens(response)
    }

    // MARK: - Token Refresh

    /// Refreshes an expired access token.
    func refreshToken(_ refreshToken: String) async throws -> AuthTokens {
        var request = Vync_Auth_RefreshTokenRequest()
        request.refreshToken = refreshToken

        SanchrLogger.auth.info("AuthDataSource: refreshToken")
        let response = try await authClient.refreshToken(request)
        try storeTokens(from: response)
        return Self.mapToAuthTokens(response)
    }

    // MARK: - Logout

    /// Invalidates the session on the server and clears local tokens.
    func logout(refreshToken: String) async throws {
        var request = Vync_Auth_LogoutRequest()
        request.refreshToken = refreshToken

        SanchrLogger.auth.info("AuthDataSource: logout")
        _ = try await authClient.logout(request)
        try clearStoredTokens()
    }

    // MARK: - Change Password

    func changePassword(currentPassword: String, newPassword: String) async throws {
        var request = Vync_Auth_ChangePasswordRequest()
        request.currentPassword = currentPassword
        request.newPassword = newPassword

        SanchrLogger.auth.info("AuthDataSource: changePassword")
        _ = try await authClient.changePassword(request)
    }

    // MARK: - Token Storage (private)

    private func storeTokens(from response: Vync_Auth_AuthResponse) throws {
        guard !response.accessToken.isEmpty else { return }
        if let data = response.accessToken.data(using: .utf8) {
            try keychainService.save(data, forKey: "io.sanchr.access_token")
        }
        if !response.refreshToken.isEmpty, let data = response.refreshToken.data(using: .utf8) {
            try keychainService.save(data, forKey: "io.sanchr.refresh_token")
        }
        SanchrLogger.auth.info("Tokens stored via AuthDataSource")
    }

    private func clearStoredTokens() throws {
        try keychainService.delete(forKey: "io.sanchr.access_token")
        try keychainService.delete(forKey: "io.sanchr.refresh_token")
        SanchrLogger.auth.info("Tokens cleared via AuthDataSource")
    }

    // MARK: - Domain Model Mapping

    /// Maps a gRPC AuthResponse to domain AuthTokens.
    static func mapToAuthTokens(_ response: Vync_Auth_AuthResponse) -> AuthTokens {
        AuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(3600),  // Default 1h expiry
            userId: response.hasUser ? response.user.id : ""
        )
    }

    /// Maps a gRPC User to domain User model.
    static func mapToUser(_ proto: Vync_Auth_User) -> User {
        User(
            id: proto.id,
            phoneNumber: proto.phoneNumber,
            displayName: proto.displayName,
            avatarURL: proto.avatarURL.isEmpty ? nil : URL(string: proto.avatarURL),
            bio: proto.statusText.isEmpty ? nil : proto.statusText,
            isVerified: true,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .online,
            isLocalUser: true
        )
    }
}
