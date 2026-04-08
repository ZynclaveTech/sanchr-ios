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

        var settings = Vync_Settings_UserSettings()
        settings.readReceipts = false
        settings.typingIndicator = true
        settings.onlineStatusVisible = true
        settings.vyncModeEnabled = false

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendReadReceipts, "cache should reflect the loaded read_receipts=false")
        XCTAssertTrue(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendPresence)
    }

    func testUpdateWithTypingOffBlocksTyping() {
        let cache = PrivacySettingsCache()

        var settings = Vync_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = false
        settings.onlineStatusVisible = true
        settings.vyncModeEnabled = false

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertTrue(cache.canSendPresence)
    }

    func testUpdateWithOnlineStatusHiddenBlocksPresence() {
        let cache = PrivacySettingsCache()

        var settings = Vync_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.onlineStatusVisible = false
        settings.vyncModeEnabled = false

        cache.update(from: settings)

        XCTAssertFalse(cache.canSendPresence)
        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertTrue(cache.canSendTypingIndicators)
    }

    func testSanchrModeBlocksEverything() {
        let cache = PrivacySettingsCache()

        var settings = Vync_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.onlineStatusVisible = true
        settings.vyncModeEnabled = true

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
                var settings = Vync_Settings_UserSettings()
                settings.readReceipts = i.isMultiple(of: 2)
                settings.typingIndicator = true
                settings.onlineStatusVisible = true
                settings.vyncModeEnabled = false
                cache.update(from: settings)
                // Reading is also under the lock, so this must not crash
                _ = cache.canSendReadReceipts
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 5.0)
    }
}
