import XCTest
import SanchrShared

@testable import Sanchr

final class DefaultDisappearingTimerTests: XCTestCase {

    func testKnownTokensMapToConversationDurations() {
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "off"), 0)
        // 30 seconds is a real option again: Android offers it, and a chat set
        // there used to match no row on this side at all.
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "30s"), 30)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "5m"), 300)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "1h"), 3600)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "24h"), 86400)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "7d"), 604_800)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "30d"), 2_592_000)
    }

    /// Older builds offered 5s and 1m defaults that no conversation could
    /// hold. Those stale values must read as "off" rather than turning on a
    /// timer nobody chose.
    func testRetiredAndUnknownTokensReadAsOff() {
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "5s"), 0)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: "1m"), 0)
        XCTAssertEqual(DefaultDisappearingTimer.seconds(forToken: ""), 0)
    }

    func testUnsetPreferenceIsOff() {
        UserDefaults.standard.removeObject(forKey: DefaultDisappearingTimer.storageKey)
        XCTAssertEqual(DefaultDisappearingTimer.seconds, 0)
    }

    func testStoredPreferenceIsRead() {
        let key = DefaultDisappearingTimer.storageKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set("1h", forKey: key)
        XCTAssertEqual(DefaultDisappearingTimer.seconds, 3600)
    }
}
