import Foundation

/// Manages the current user session: token storage, refresh, and auth state.
@Observable
final class SessionService: @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol
    private let authRepository: AuthRepositoryProtocol

    /// Whether the user is currently authenticated.
    private(set) var isAuthenticated: Bool = false

    /// The current user's ID (nil if not authenticated).
    private(set) var currentUserId: String?

    /// Token expiration date.
    private var tokenExpiresAt: Date?

    init(secureStorage: SecureStorageProtocol, authRepository: AuthRepositoryProtocol) {
        self.secureStorage = secureStorage
        self.authRepository = authRepository

        // Check for existing session on init
        if let _ = try? secureStorage.readAccessToken() {
            isAuthenticated = true
            // TODO: Read userId from stored session data
        }
    }

    /// Stores authentication tokens and updates session state.
    func storeTokens(_ tokens: AuthTokens) async throws {
        try secureStorage.saveAccessToken(tokens.accessToken)
        try secureStorage.saveRefreshToken(tokens.refreshToken)
        tokenExpiresAt = tokens.expiresAt
        currentUserId = tokens.userId
        isAuthenticated = true

        SanchrLogger.auth.info("Session tokens stored, expires at \(tokens.expiresAt)")
    }

    /// Returns the current access token, refreshing if necessary.
    func validAccessToken() async throws -> String {
        guard let token = try secureStorage.readAccessToken() else {
            throw AppError.sessionExpired
        }

        // Check if token is expired or about to expire (within 5 minutes)
        if let expiresAt = tokenExpiresAt,
           expiresAt.timeIntervalSinceNow < 300 {
            return try await refreshToken()
        }

        return token
    }

    /// Refreshes the access token using the stored refresh token.
    private func refreshToken() async throws -> String {
        guard let refreshToken = try secureStorage.readRefreshToken() else {
            await clearSessionState()
            throw AppError.sessionExpired
        }

        SanchrLogger.auth.info("Refreshing access token")

        do {
            let tokens = try await authRepository.refreshToken(refreshToken: refreshToken)
            try await storeTokens(tokens)
            return tokens.accessToken
        } catch {
            SanchrLogger.auth.error("Token refresh failed: \(error.localizedDescription)")
            await clearSessionState()
            throw AppError.sessionExpired
        }
    }

    /// Clears the session and logs out.
    func clearSession() async throws {
        if let token = try? secureStorage.readAccessToken() {
            try? await authRepository.logout(accessToken: token)
        }
        try secureStorage.deleteAllTokens()
        await clearSessionState()
    }

    @MainActor
    private func clearSessionState() {
        isAuthenticated = false
        currentUserId = nil
        tokenExpiresAt = nil
    }
}
