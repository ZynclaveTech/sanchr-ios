import XCTest
import SanchrShared

@testable import Sanchr

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
            authRepository: MockAuthRepository()
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

    func testRefreshFailureExpiresSessionAndPurgesSnapshot() async {
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

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.currentUserId)
        XCTAssertNil(storage.sessionSnapshot)
        XCTAssertEqual(storage.deleteSessionDataCallCount, 1)
        let cleanupValue = await cleanupCounter.value
        XCTAssertEqual(cleanupValue, 1)
    }
}
