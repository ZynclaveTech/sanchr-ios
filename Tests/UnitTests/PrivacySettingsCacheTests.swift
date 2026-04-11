import XCTest
import SanchrShared

@testable import Sanchr

/// Pins the PrivacySettingsCache update contract that the PrivacyView
/// fix depends on. The bug this regression test guards against: if
/// PrivacyView forgets to thread `privacySettings: container.privacySettings`
/// into `SettingsViewModel.loadSettings`, the cache stays at its default
/// values and local enforcement (canSendReadReceipts / canSendTypingIndicators
/// / canSendPresence) silently lies for the rest of the session.
///
/// The tests below exercise `update(from:)` directly because that is the
/// method `loadSettings` calls internally. If anyone ever refactors
/// `PrivacySettingsCache` such that `update(from:)` no longer flips the
/// getter values, these tests will catch it before PrivacyView does.
final class PrivacySettingsCacheTests: XCTestCase {

    func testDefaultsAllowAllPrivacyActions() {
        let cache = PrivacySettingsCache()

        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertTrue(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendPresence)
    }

    func testUpdateWithReadReceiptsOffBlocksReadReceipts() {
        let cache = PrivacySettingsCache()

        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = false
        settings.typingIndicator = true
        settings.onlineStatusVisible = true
        settings.sanchrModeEnabled = false

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendReadReceipts, "cache should reflect the loaded read_receipts=false")
        XCTAssertTrue(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendPresence)
    }

    func testUpdateWithTypingOffBlocksTyping() {
        let cache = PrivacySettingsCache()

        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = false
        settings.onlineStatusVisible = true
        settings.sanchrModeEnabled = false

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertTrue(cache.canSendPresence)
    }

    func testUpdateWithOnlineStatusHiddenBlocksPresence() {
        let cache = PrivacySettingsCache()

        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.onlineStatusVisible = false
        settings.sanchrModeEnabled = false

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendPresence)
        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertTrue(cache.canSendTypingIndicators)
    }

    func testSanchrModeBlocksEverything() {
        let cache = PrivacySettingsCache()

        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.onlineStatusVisible = true
        settings.sanchrModeEnabled = true

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendReadReceipts, "Sanchr Mode gates all privacy actions")
        XCTAssertFalse(cache.canSendTypingIndicators)
        XCTAssertFalse(cache.canSendPresence)
    }

    func testUpdateIsThreadSafe() {
        // The cache is documented as thread-safe. Hit it from multiple
        // tasks simultaneously to flush out any race regression.
        let cache = PrivacySettingsCache()
        let exp = expectation(description: "all updates complete")
        exp.expectedFulfillmentCount = 50

        for i in 0..<50 {
            DispatchQueue.global().async {
                var settings = Sanchr_Settings_UserSettings()
                settings.readReceipts = i.isMultiple(of: 2)
                settings.typingIndicator = true
                settings.onlineStatusVisible = true
                settings.sanchrModeEnabled = false
                cache.update(from: settings)
                // Reading is also under the lock, so this must not crash
                _ = cache.canSendReadReceipts
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 5.0)
    }

    func test_clear_resetsAllFields() {
        let cache = PrivacySettingsCache()

        var populated = Sanchr_Settings_UserSettings()
        populated.readReceipts = false
        populated.typingIndicator = false
        populated.onlineStatusVisible = false
        populated.sanchrModeEnabled = true
        populated.profilePhotoVisibility = "contacts"
        cache.update(from: populated)
        cache.update(blockList: ["u1", "u2"])

        cache.clear()

        XCTAssertTrue(cache.canSendReadReceipts, "clear() restores readReceipts default")
        XCTAssertTrue(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendPresence)
        XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
        XCTAssertTrue(cache.blockedUserIds.isEmpty)
        XCTAssertFalse(cache.isBlocked("u1"))
    }

    func test_updateFromSettings_populatesProfilePhotoVisibility() {
        let cache = PrivacySettingsCache()

        var settings = Sanchr_Settings_UserSettings()
        settings.profilePhotoVisibility = "contacts"
        cache.update(from: settings)

        XCTAssertEqual(cache.profilePhotoVisibility, "contacts")
    }

    func test_updateFromSettings_emptyProfilePhotoVisibilityFallsBackToEveryone() {
        let cache = PrivacySettingsCache()

        var settings = Sanchr_Settings_UserSettings()
        settings.profilePhotoVisibility = ""
        cache.update(from: settings)

        XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
    }

    func test_isBlocked_reflectsBlockListUpdate() {
        let cache = PrivacySettingsCache()

        cache.update(blockList: ["u1", "u2"])

        XCTAssertTrue(cache.isBlocked("u1"))
        XCTAssertTrue(cache.isBlocked("u2"))
        XCTAssertFalse(cache.isBlocked("u3"))
        XCTAssertEqual(cache.blockedUserIds, ["u1", "u2"])
    }

    func test_concurrentClearAndRead_doesNotCrash() {
        let cache = PrivacySettingsCache()

        let expectation = XCTestExpectation(description: "concurrent access")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for _ in 0..<2000 {
                cache.clear()
            }
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            for _ in 0..<2000 {
                _ = cache.canSendReadReceipts
                _ = cache.profilePhotoVisibility
                _ = cache.isBlocked("u1")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}
