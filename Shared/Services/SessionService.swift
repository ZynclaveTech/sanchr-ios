import Foundation
import GRPC
import SanchrShared

/// Manages the current user session: token storage, refresh, and auth state.
@Observable
final class SessionService: @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol
    private let authRepository: AuthRepositoryProtocol
    private let cleanup: @Sendable () async -> Void
    private let deepWipe: @Sendable () async -> Void
    private let privacySettings: PrivacySettingsCache

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

    /// Fires every 3 minutes while authenticated to proactively refresh the access
    /// token before it expires. This catches the case where the app stays in the
    /// foreground for the full token lifetime without a foreground-transition sync.
    private var periodicRefreshTask: Task<Void, Never>?

    init(
        secureStorage: SecureStorageProtocol,
        authRepository: AuthRepositoryProtocol,
        privacySettings: PrivacySettingsCache,
        cleanup: @escaping @Sendable () async -> Void = {},
        deepWipe: @escaping @Sendable () async -> Void = {}
    ) {
        self.secureStorage = secureStorage
        self.authRepository = authRepository
        self.privacySettings = privacySettings
        self.cleanup = cleanup
        self.deepWipe = deepWipe
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
        // Only overwrite the stored refresh token if the server returned a non-empty one.
        // Servers that do not rotate refresh tokens return an empty string; persisting
        // it would clobber the valid token already in Keychain.
        if !tokens.refreshToken.isEmpty {
            try secureStorage.saveRefreshToken(tokens.refreshToken)
        }
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
        startPeriodicTokenRefresh()
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
    ///
    /// Error discrimination:
    /// - UNAUTHENTICATED from server: token is revoked/invalid → wipe session immediately.
    /// - Network/server errors: retry up to 2 times with 1 s / 3 s backoff.
    ///   If all retries fail, the session is kept alive (user is offline) and the
    ///   raw error is rethrown so the caller can handle gracefully.
    private func refreshToken() async throws -> String {
        // If a refresh is already running, join it
        if let existing = activeRefreshTask {
            return try await existing.value
        }

        let task = Task<String, Error> {
            defer { activeRefreshTask = nil }

            guard let storedRefreshToken = try? secureStorage.readRefreshToken(),
                  !storedRefreshToken.isEmpty else {
                try? secureStorage.deleteSessionData()
                await clearSessionState()
                await cleanup()
                throw AppError.sessionExpired
            }

            SanchrLogger.auth.info("Refreshing access token")

            let retryDelays: [UInt64] = [1_000_000_000, 3_000_000_000] // 1 s, 3 s

            for attempt in 0...2 {
                do {
                    let tokens = try await authRepository.refreshToken(refreshToken: storedRefreshToken)
                    try await storeTokens(tokens)
                    return tokens.accessToken
                } catch let grpcError as GRPCStatus where grpcError.code == .unauthenticated {
                    // Server explicitly rejected the token — it is revoked or invalid.
                    // Logout immediately; no retry makes sense here.
                    SanchrLogger.auth.error(
                        "Token refresh rejected by server (UNAUTHENTICATED) — clearing session"
                    )
                    try? secureStorage.deleteSessionData()
                    await clearSessionState()
                    await cleanup()
                    throw AppError.sessionExpired
                } catch {
                    if attempt < 2 {
                        SanchrLogger.auth.warning(
                            "Token refresh attempt \(attempt + 1) failed (\(error.localizedDescription)), retrying..."
                        )
                        try? await Task.sleep(nanoseconds: retryDelays[attempt])
                        continue
                    }
                    // All retries exhausted; keep session alive so the user is not
                    // logged out just because the network is temporarily unavailable.
                    SanchrLogger.auth.error(
                        "All token refresh attempts failed — keeping session alive: \(error.localizedDescription)"
                    )
                    throw error
                }
            }

            // Unreachable: the loop above always returns or throws.
            throw AppError.sessionExpired
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

    /// Permanently deletes the user's account on the server and wipes ALL
    /// local artifacts (including App Group state). On server failure no
    /// local wipe is performed so the user can retry without being stranded.
    func deleteAccount() async throws {
        SanchrLogger.auth.warning("Attempting account deletion on server")
        try await authRepository.deleteAccount()
        SanchrLogger.auth.warning("Account deletion confirmed; wiping local artifacts")

        try? secureStorage.deleteSessionData()
        await clearSessionState()
        await cleanup()
        await deepWipe()
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
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        privacySettings.clear()
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

        let storedSnapshot = (try? secureStorage.readSessionSnapshot()) ?? nil

        guard
            let snapshot = storedSnapshot,
            let storedRefreshToken = try? secureStorage.readRefreshToken(),
            !storedRefreshToken.isEmpty
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
        startPeriodicTokenRefresh()
    }

    // MARK: - Periodic Token Refresh

    /// Starts a background loop that checks every 3 minutes whether the access token
    /// is within 5 minutes of expiry and refreshes it proactively.
    ///
    /// This guards against the case where the app stays in the foreground for the
    /// full token lifetime without a background→foreground transition (which is the
    /// only other path that triggers proactive refresh via SyncOrchestrator).
    ///
    /// Safe to call repeatedly — cancels any running loop before starting a new one.
    private func startPeriodicTokenRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(180))  // 3-minute interval
                } catch {
                    return  // CancellationError — exit cleanly
                }
                guard let self, self.isAuthenticated, !Task.isCancelled else { break }
                _ = try? await self.refreshTokenIfExpiringSoon()
            }
        }
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
