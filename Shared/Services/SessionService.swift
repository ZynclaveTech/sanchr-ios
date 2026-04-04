import Foundation
import GRPC

/// Manages the current user session: token storage, refresh, and auth state.
@Observable
final class SessionService: @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol
    private let authRepository: AuthRepositoryProtocol
    private let cleanup: @Sendable () async -> Void

    /// Whether the user is currently authenticated.
    private(set) var isAuthenticated: Bool = false

    /// The current user's ID (nil if not authenticated).
    private(set) var currentUserId: String?

    /// The current user's display name (nil if not authenticated).
    private(set) var currentDisplayName: String?

    /// The current user's phone number (nil if not authenticated).
    private(set) var currentPhoneNumber: String?

    /// The current user's avatar URL (nil if not set).
    private(set) var currentAvatarURL: String?

    /// The current server-issued device ID (if authenticated).
    private(set) var currentDeviceId: String?

    /// Stable per-installation identifier used for device upsert.
    private(set) var currentInstallationId: String?

    /// High-water mark used for incremental message sync.
    private(set) var lastMessageSyncTimestamp: Int64 = 0

    /// Token expiration date.
    private var tokenExpiresAt: Date?

    /// Guards against concurrent refresh requests.
    private var activeRefreshTask: Task<String, Error>?

    init(
        secureStorage: SecureStorageProtocol,
        authRepository: AuthRepositoryProtocol,
        cleanup: @escaping @Sendable () async -> Void = {}
    ) {
        self.secureStorage = secureStorage
        self.authRepository = authRepository
        self.cleanup = cleanup
        restorePersistedSession()
    }

    // MARK: - Token Validity

    /// Whether the current access token is valid and not expired.
    var isTokenValid: Bool {
        guard isAuthenticated else { return false }
        guard (try? secureStorage.readAccessToken()) != nil else { return false }

        // If we have no expiry info, assume valid (will be checked on next API call).
        guard let expiresAt = tokenExpiresAt else { return true }

        // Token is valid if it has more than 0 seconds remaining.
        return expiresAt.timeIntervalSinceNow > 0
    }

    /// Stores authentication tokens and updates session state.
    func storeTokens(_ tokens: AuthTokens) async throws {
        try secureStorage.saveAccessToken(tokens.accessToken)
        try secureStorage.saveRefreshToken(tokens.refreshToken)
        if let deviceId = tokens.deviceId {
            try secureStorage.saveDeviceId(deviceId)
            currentDeviceId = deviceId
        }

        let installationId = try secureStorage.readOrCreateInstallationId()
        tokenExpiresAt = tokens.expiresAt
        currentInstallationId = installationId
        currentUserId = tokens.userId
        currentDisplayName = tokens.displayName.isEmpty ? currentDisplayName : tokens.displayName
        currentPhoneNumber = tokens.phoneNumber.isEmpty ? currentPhoneNumber : tokens.phoneNumber
        currentAvatarURL = tokens.avatarURL.isEmpty ? currentAvatarURL : tokens.avatarURL
        isAuthenticated = true
        try persistSnapshot()

        SanchrLogger.auth.info("Session tokens stored, expires at \(tokens.expiresAt)")
    }

    /// Returns the current access token, refreshing if necessary.
    func validAccessToken() async throws -> String {
        guard let token = try secureStorage.readAccessToken() else {
            throw AppError.sessionExpired
        }

        // Check if token is expired or about to expire (within 5 minutes)
        if let expiresAt = tokenExpiresAt,
            expiresAt.timeIntervalSinceNow < 300
        {
            return try await refreshToken()
        }

        return token
    }

    /// Refreshes the access token if it will expire within 5 minutes.
    /// Does nothing if the token is still valid with more than 5 minutes remaining.
    /// - Throws: `AppError.sessionExpired` if the refresh fails.
    @discardableResult
    func refreshTokenIfExpiringSoon() async throws -> String {
        guard isAuthenticated else {
            throw AppError.sessionExpired
        }

        guard let token = try secureStorage.readAccessToken() else {
            throw AppError.sessionExpired
        }

        // If no expiry is tracked or token has more than 5 minutes left, return as-is.
        if let expiresAt = tokenExpiresAt,
            expiresAt.timeIntervalSinceNow < 300
        {
            SanchrLogger.auth.info("Token expiring soon, refreshing proactively")
            return try await refreshToken()
        }

        return token
    }

    /// Forces a token refresh regardless of expiry state.
    /// Called by the auth interceptor when the server returns UNAUTHENTICATED.
    /// Coalesces concurrent calls — if a refresh is already in progress, joins it.
    @discardableResult
    func forceRefreshToken() async throws -> String {
        guard isAuthenticated else {
            throw AppError.sessionExpired
        }

        // If a refresh is already running, join it instead of starting another
        if let existing = activeRefreshTask {
            SanchrLogger.auth.info("Joining existing token refresh task")
            return try await existing.value
        }

        SanchrLogger.auth.info("Force-refreshing access token (server returned UNAUTHENTICATED)")
        return try await refreshToken()
    }

    /// Refreshes the access token using the stored refresh token.
    /// Coalesces concurrent refresh attempts into a single network call.
    private func refreshToken() async throws -> String {
        // If a refresh is already running, join it
        if let existing = activeRefreshTask {
            return try await existing.value
        }

        let task = Task<String, Error> {
            defer { activeRefreshTask = nil }

            guard let refreshToken = try secureStorage.readRefreshToken() else {
                try? secureStorage.deleteSessionData()
                await clearSessionState()
                await cleanup()
                throw AppError.sessionExpired
            }

            SanchrLogger.auth.info("Refreshing access token")

            do {
                let tokens = try await authRepository.refreshToken(refreshToken: refreshToken)
                try await storeTokens(tokens)
                return tokens.accessToken
            } catch {
                SanchrLogger.auth.error("Token refresh failed: \(error.localizedDescription)")
                try? secureStorage.deleteSessionData()
                await clearSessionState()
                await cleanup()
                throw AppError.sessionExpired
            }
        }

        activeRefreshTask = task
        return try await task.value
    }

    /// Executes a gRPC call with automatic retry on UNAUTHENTICATED.
    /// On first failure, refreshes the token and retries once.
    func withAuthRetry<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let status as GRPCStatus where status.code == .unauthenticated {
            SanchrLogger.auth.info("Got UNAUTHENTICATED, refreshing token and retrying")
            _ = try await forceRefreshToken()
            return try await operation()
        }
    }

    /// Updates the locally cached profile fields (after a profile save).
    func updateProfile(displayName: String?, avatarURL: String?) {
        if let displayName, !displayName.isEmpty {
            currentDisplayName = displayName
        }
        if let avatarURL {
            currentAvatarURL = avatarURL
        }
        try? persistSnapshot()
    }

    func setLastMessageSyncTimestamp(_ timestamp: Int64) {
        guard timestamp > lastMessageSyncTimestamp else { return }
        lastMessageSyncTimestamp = timestamp
        try? persistSnapshot()
    }

    /// Clears the session and logs out.
    func clearSession() async throws {
        if let token = try? secureStorage.readAccessToken() {
            try? await authRepository.logout(accessToken: token)
        }
        try secureStorage.deleteSessionData()
        await clearSessionState()
        await cleanup()
    }

    @MainActor
    private func clearSessionState() {
        isAuthenticated = false
        currentUserId = nil
        currentDisplayName = nil
        currentPhoneNumber = nil
        currentAvatarURL = nil
        currentDeviceId = nil
        currentInstallationId = nil
        lastMessageSyncTimestamp = 0
        tokenExpiresAt = nil
    }

    private func restorePersistedSession() {
        currentInstallationId = try? secureStorage.readOrCreateInstallationId()
        currentDeviceId = try? secureStorage.readDeviceId()

        let storedAccessToken = (try? secureStorage.readAccessToken()) ?? nil
        let storedSnapshot = (try? secureStorage.readSessionSnapshot()) ?? nil

        guard
            let snapshot = storedSnapshot,
            let storedAccessToken,
            !storedAccessToken.isEmpty
        else {
            return
        }

        isAuthenticated = true
        currentUserId = snapshot.userId
        currentDisplayName = snapshot.displayName
        currentPhoneNumber = snapshot.phoneNumber
        currentAvatarURL = snapshot.avatarURL
        tokenExpiresAt = snapshot.tokenExpiresAt
        currentDeviceId = snapshot.deviceId ?? currentDeviceId
        currentInstallationId = snapshot.installationId
        lastMessageSyncTimestamp = snapshot.lastMessageSyncTimestamp
    }

    private func persistSnapshot() throws {
        guard
            let currentUserId,
            let currentInstallationId
        else {
            return
        }

        let snapshot = SessionSnapshot(
            userId: currentUserId,
            displayName: currentDisplayName ?? "",
            phoneNumber: currentPhoneNumber ?? "",
            avatarURL: currentAvatarURL,
            tokenExpiresAt: tokenExpiresAt,
            deviceId: currentDeviceId,
            installationId: currentInstallationId,
            lastMessageSyncTimestamp: lastMessageSyncTimestamp
        )
        try secureStorage.saveSessionSnapshot(snapshot)
    }
}
