import XCTest
import SanchrShared

@testable import Sanchr

@MainActor
final class SessionServiceTests: XCTestCase {
    private actor CleanupCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    func testRestorePersistedSessionSnapshotOnInit() {
        let storage = MockSecureStorage()
        storage.accessToken = "access-token"
        storage.refreshToken = "refresh-token"
        storage.deviceId = "5"
        storage.installationId = "install-123"
        storage.sessionSnapshot = SessionSnapshot(
            userId: "user-123",
            displayName: "Sanchr User",
            phoneNumber: "+15551234567",
            avatarURL: "https://example.com/avatar.png",
            tokenExpiresAt: Date().addingTimeInterval(3600),
            deviceId: "5",
            installationId: "install-123",
            lastMessageSyncTimestamp: 9001
        )

        let service = SessionService(
            secureStorage: storage,
            authRepository: MockAuthRepository(),
            privacySettings: PrivacySettingsCache()
        )

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.currentUserId, "user-123")
        XCTAssertEqual(service.currentDisplayName, "Sanchr User")
        XCTAssertEqual(service.currentPhoneNumber, "+15551234567")
        XCTAssertEqual(service.currentAvatarURL, "https://example.com/avatar.png")
        XCTAssertEqual(service.currentDeviceId, "5")
        XCTAssertEqual(service.currentInstallationId, "install-123")
        XCTAssertEqual(service.lastMessageSyncTimestamp, 9001)
    }

    func testClearSessionDeletesPersistedStateAndRunsCleanup() async throws {
        let storage = MockSecureStorage()
        let authRepository = MockAuthRepository()
        let cleanupCounter = CleanupCounter()
        let service = SessionService(
            secureStorage: storage,
            authRepository: authRepository,
            privacySettings: PrivacySettingsCache(),
            cleanup: {
                await cleanupCounter.increment()
            }
        )

        try await service.storeTokens(
            AuthTokens(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(3600),
                userId: "user-123",
                displayName: "Sanchr User",
                phoneNumber: "+15551234567",
                avatarURL: "",
                deviceId: "11"
            )
        )

        XCTAssertTrue(service.isAuthenticated)

        try await service.clearSession()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUserId)
        XCTAssertNil(service.currentDeviceId)
        XCTAssertNil(service.currentInstallationId)
        XCTAssertEqual(storage.deleteSessionDataCallCount, 1)
        XCTAssertEqual(authRepository.logoutAccessTokens, ["access-token"])
        let cleanupValue = await cleanupCounter.value
        XCTAssertEqual(cleanupValue, 1)
    }

    /// An involuntary expiry — the server rejected the refresh token — must
    /// drop the tokens and the in-memory auth state but leave every local
    /// artifact alone, so re-authenticating on the same device restores the
    /// account instead of costing the user their history. The destructive
    /// `deleteSessionData()`/`cleanup()` wipe belongs to a deliberate logout
    /// or account deletion only.
    ///
    /// This test previously asserted the opposite and was left behind when
    /// that behaviour was intentionally reversed; it went unnoticed because
    /// the test target had stopped compiling.
    func testRefreshFailureExpiresSessionButKeepsLocalData() async {
        let storage = MockSecureStorage()
        storage.accessToken = "expired-access"
        storage.refreshToken = "refresh-token"
        storage.deviceId = "17"
        storage.installationId = "install-17"
        storage.sessionSnapshot = SessionSnapshot(
            userId: "user-17",
            displayName: "Expired User",
            phoneNumber: "+15550000000",
            avatarURL: nil,
            tokenExpiresAt: Date().addingTimeInterval(-60),
            deviceId: "17",
            installationId: "install-17",
            lastMessageSyncTimestamp: 50
        )

        let authRepository = MockAuthRepository()
        authRepository.refreshTokensResult = .failure(AppError.sessionExpired)

        let cleanupCounter = CleanupCounter()
        let service = SessionService(
            secureStorage: storage,
            authRepository: authRepository,
            privacySettings: PrivacySettingsCache(),
            cleanup: {
                await cleanupCounter.increment()
            }
        )

        do {
            _ = try await service.forceRefreshToken()
            XCTFail("Expected refresh to fail")
        } catch let error as AppError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // The session is over: auth state is gone and the rejected tokens are
        // deleted so nothing retries with them.
        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUserId)
        XCTAssertEqual(storage.deleteAllTokensCallCount, 1)

        // ...but the user's data survives, ready for re-authentication on this
        // same device.
        XCTAssertNotNil(
            storage.sessionSnapshot,
            "an involuntary expiry must not purge the session snapshot"
        )
        XCTAssertEqual(
            storage.deleteSessionDataCallCount, 0,
            "deleteSessionData is reserved for a deliberate logout"
        )
        let cleanupValue = await cleanupCounter.value
        XCTAssertEqual(
            cleanupValue, 0,
            "the destructive local-data cleanup must not run on a token timeout"
        )
    }

    // MARK: - Reset Message Sync High-Water Mark

    /// Regression guard: `resetLocalDataAfterBootstrapFailure` in
    /// `DependencyContainer` relies on this method to zero the high-water
    /// mark so the next server sync pulls full history instead of only
    /// messages newer than the stale mark. If this behavior regresses,
    /// users who hit `LocalDataRecoveryView` on reinstall silently lose
    /// their entire message history.
    func testResetMessageSyncHighWaterMarkZerosValueAndPersists() {
        let storage = MockSecureStorage()
        storage.refreshToken = "refresh-token"
        storage.sessionSnapshot = SessionSnapshot(
            userId: "user-123",
            displayName: "Sanchr User",
            phoneNumber: "+15551234567",
            avatarURL: nil,
            tokenExpiresAt: Date().addingTimeInterval(3600),
            deviceId: "5",
            installationId: "install-123",
            lastMessageSyncTimestamp: 1_750_000_000_000
        )

        let service = SessionService(
            secureStorage: storage,
            authRepository: MockAuthRepository(),
            privacySettings: PrivacySettingsCache()
        )

        XCTAssertEqual(service.lastMessageSyncTimestamp, 1_750_000_000_000)

        service.resetMessageSyncHighWaterMark()

        XCTAssertEqual(service.lastMessageSyncTimestamp, 0)
        XCTAssertEqual(storage.sessionSnapshot?.lastMessageSyncTimestamp, 0)
    }

    /// The high-water mark reset must bypass the forward-only guard in
    /// `setLastMessageSyncTimestamp`. This test is what prevents someone
    /// from "simplifying" the reset path by routing it through the setter.
    func testResetMessageSyncHighWaterMarkBypassesForwardOnlyGuard() {
        let storage = MockSecureStorage()
        storage.refreshToken = "refresh-token"
        storage.sessionSnapshot = SessionSnapshot(
            userId: "user-123",
            displayName: "Sanchr User",
            phoneNumber: "+15551234567",
            avatarURL: nil,
            tokenExpiresAt: Date().addingTimeInterval(3600),
            deviceId: "5",
            installationId: "install-123",
            lastMessageSyncTimestamp: 42
        )

        let service = SessionService(
            secureStorage: storage,
            authRepository: MockAuthRepository(),
            privacySettings: PrivacySettingsCache()
        )

        // setLastMessageSyncTimestamp refuses to go backwards.
        service.setLastMessageSyncTimestamp(0)
        XCTAssertEqual(service.lastMessageSyncTimestamp, 42, "Sanity: forward-only guard blocks zero.")

        // resetMessageSyncHighWaterMark must bypass that guard.
        service.resetMessageSyncHighWaterMark()
        XCTAssertEqual(service.lastMessageSyncTimestamp, 0)
        XCTAssertEqual(storage.sessionSnapshot?.lastMessageSyncTimestamp, 0)
    }
}
