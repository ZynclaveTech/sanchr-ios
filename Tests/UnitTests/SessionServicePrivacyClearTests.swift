import XCTest
import SanchrShared

@testable import Sanchr

@MainActor
final class SessionServicePrivacyClearTests: XCTestCase {

    func test_clearSession_resetsCacheToDefaults() async throws {
        let cache = PrivacySettingsCache()
        var populated = Sanchr_Settings_UserSettings()
        populated.readReceipts = false
        populated.typingIndicator = false
        populated.onlineStatusVisible = false
        populated.sanchrModeEnabled = true
        populated.profilePhotoVisibility = "nobody"
        cache.update(from: populated)
        cache.update(blockList: ["u1"])

        XCTAssertFalse(cache.canSendReadReceipts)
        XCTAssertFalse(cache.canSendTypingIndicators)
        XCTAssertEqual(cache.profilePhotoVisibility, "nobody")
        XCTAssertTrue(cache.isBlocked("u1"))

        let service = SessionService(
            secureStorage: MockSecureStorage(),
            authRepository: MockAuthRepository(),
            privacySettings: cache
        )
        try await service.clearSession()

        XCTAssertTrue(cache.canSendReadReceipts, "clear on logout must restore defaults")
        XCTAssertTrue(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendPresence)
        XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
        XCTAssertTrue(cache.blockedUserIds.isEmpty)
    }

    func test_clearSession_idempotent() async throws {
        let cache = PrivacySettingsCache()
        let service = SessionService(
            secureStorage: MockSecureStorage(),
            authRepository: MockAuthRepository(),
            privacySettings: cache
        )

        try await service.clearSession()
        try await service.clearSession()

        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
    }
}
