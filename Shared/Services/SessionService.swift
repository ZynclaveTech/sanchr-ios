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

    /// The current user's status text / bio (nil if not set).
    private(set) var currentStatusText: String?

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
        // `tokens.displayName` comes from the server's plaintext users.display_name,
        // which is vestigial: UpdateProfile has sent ciphertext only since profile
        // fields became E2EE, so that column still holds the registration
        // placeholder no matter what the user chose. Letting it win here reset the
        // name to "Sanchr User" on every token refresh, and RootView reads an
        // unset name as incomplete onboarding — so a refresh triggered by any
        // ordinary action dropped the user back on the name step.
        //
        // The real name lives in the encrypted profile and in the session
        // snapshot; neither is improved by anything the server can tell us here.
        if !tokens.displayName.isEmpty, tokens.displayName != User.serverPlaceholderDisplayName {
            currentDisplayName = tokens.displayName
        }
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

        // Refresh if: expiry is unknown (treat as expired), or token expires within 5 minutes.
        // Using a 5-minute buffer ensures the main UI always starts with a fresh token.
        let needsRefresh: Bool
        if let expiresAt = tokenExpiresAt {
            needsRefresh = expiresAt.timeIntervalSinceNow < 300
        } else {
            // No expiry info — could be a snapshot from an older build. Refresh defensively.
            needsRefresh = true
        }

        if needsRefresh {
            SanchrLogger.auth.info("Token expiring soon or expiry unknown, refreshing proactively")
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
                await clearSessionForReauth()
                throw AppError.sessionExpired
            }

            SanchrLogger.auth.info("Refreshing access token")

            let retryDelays: [UInt64] = [1_000_000_000, 3_000_000_000] // 1 s, 3 s

            for attempt in 0...2 {
                do {
                    let tokens = try await authRepository.refreshToken(refreshToken: storedRefreshToken)
                    try await storeTokens(tokens)
                    return tokens.accessToken
                } catch let appError as AppError where appError == .sessionExpired {
                    SanchrLogger.auth.error(
                        "Token refresh reported session expiration — clearing session"
                    )
                    await clearSessionForReauth()
                    throw appError
                } catch let grpcError as GRPCStatus where grpcError.code == .unauthenticated {
                    // Server explicitly rejected the token — it is revoked or invalid.
                    // Logout immediately; no retry makes sense here.
                    SanchrLogger.auth.error(
                        "Token refresh rejected by server (UNAUTHENTICATED) — clearing session"
                    )
                    await clearSessionForReauth()
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
    func updateProfile(displayName: String?, avatarURL: String?, statusText: String? = nil) {
        if let displayName, !displayName.isEmpty {
            currentDisplayName = displayName
        }
        if let avatarURL {
            currentAvatarURL = avatarURL
        }
        if let statusText {
            currentStatusText = statusText
        }
        try? persistSnapshot()
    }

    func setLastMessageSyncTimestamp(_ timestamp: Int64) {
        guard timestamp > lastMessageSyncTimestamp else { return }
        lastMessageSyncTimestamp = timestamp
        schedulePersistSnapshot()
    }

    // MARK: - Coalesced Snapshot Persistence

    /// The snapshot lives in the Keychain, and this used to be written on
    /// every realtime message — a Keychain round trip per message during a
    /// burst. The high-water mark only has to be durable eventually: a
    /// crash before the write replays a few messages, which the replay
    /// gate already de-duplicates. So writes are coalesced, and anything
    /// that ends the session or backgrounds the app flushes first.
    private var pendingSnapshotPersist: Task<Void, Never>?
    private static let snapshotPersistDelay: Duration = .seconds(2)

    private func schedulePersistSnapshot() {
        pendingSnapshotPersist?.cancel()
        pendingSnapshotPersist = Task { [weak self] in
            try? await Task.sleep(for: Self.snapshotPersistDelay)
            guard !Task.isCancelled, let self else { return }
            try? self.persistSnapshot()
            self.pendingSnapshotPersist = nil
        }
    }

    /// Writes any coalesced snapshot now. Call before the process may be
    /// suspended or the session torn down.
    func flushPendingSnapshot() {
        guard pendingSnapshotPersist != nil else { return }
        pendingSnapshotPersist?.cancel()
        pendingSnapshotPersist = nil
        try? persistSnapshot()
    }

    /// Drops a coalesced write without performing it. Used when the
    /// session data is about to be deleted, so a late write cannot
    /// resurrect it.
    private func cancelPendingSnapshot() {
        pendingSnapshotPersist?.cancel()
        pendingSnapshotPersist = nil
    }

    /// Resets the incremental-sync high-water mark to 0 and persists the
    /// updated session snapshot. Used by `resetLocalSecrets` after the local
    /// database has been destroyed so that the next `syncPendingMessages`
    /// call re-downloads the full server-side message history instead of
    /// requesting only messages newer than the stale high-water mark.
    ///
    /// Bypasses the forward-only guard in `setLastMessageSyncTimestamp`
    /// because this is an explicit reset, not a sync-progress update.
    func resetMessageSyncHighWaterMark() {
        lastMessageSyncTimestamp = 0
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
        cancelPendingSnapshot()
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        privacySettings.clear()
        isAuthenticated = false
        currentUserId = nil
        currentDisplayName = nil
        currentPhoneNumber = nil
        currentAvatarURL = nil
        currentStatusText = nil
        currentDeviceId = nil
        currentInstallationId = nil
        lastMessageSyncTimestamp = 0
        tokenExpiresAt = nil
    }

    /// Clears the session for an *involuntary* expiry (the refresh token was
    /// rejected) without destroying any local data.
    ///
    /// An expired session must never cost the user their history. This drops only
    /// the now-invalid access/refresh tokens and the in-memory auth state, so the
    /// app returns to sign-in — but the message database, Signal sessions, device
    /// identity (deviceId/installationId), and Profile Key are all left intact, so
    /// re-authenticating as the same device restores the account seamlessly. The
    /// destructive `cleanup()`/`deleteSessionData()` wipe is reserved for a
    /// deliberate logout or account deletion, never a token timeout.
    private func clearSessionForReauth() async {
        try? secureStorage.deleteAllTokens()
        await clearSessionState()
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
        currentStatusText = snapshot.statusText
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
            statusText: currentStatusText,
            tokenExpiresAt: tokenExpiresAt,
            deviceId: currentDeviceId,
            installationId: currentInstallationId,
            lastMessageSyncTimestamp: lastMessageSyncTimestamp
        )
        try secureStorage.saveSessionSnapshot(snapshot)
    }
}
