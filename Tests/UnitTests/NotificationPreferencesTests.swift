import XCTest
import SanchrShared

@testable import Sanchr

/// The Notifications screen used to push only — it never read stored values
/// back, so every open showed hardcoded defaults and touching one toggle
/// synced that wrong state to the server. These cover the decode that fixes it.
final class NotificationPreferencesTests: XCTestCase {

    private func settings(
        message: Bool = true,
        call: Bool = true,
        group: Bool = true,
        preview: Bool = true,
        vibrate: Bool = true,
        sound: String = ""
    ) -> Sanchr_Settings_UserSettings {
        var s = Sanchr_Settings_UserSettings()
        s.messageNotifications = message
        s.callNotifications = call
        s.groupNotifications = group
        s.showPreview = preview
        s.notificationVibrate = vibrate
        s.notificationSound = sound
        return s
    }

    func testEveryToggleIsRead() {
        let prefs = NotificationPreferences(
            from: settings(
                message: false, call: true, group: false, preview: false, vibrate: false)
        )
        XCTAssertFalse(prefs.messageNotifications)
        XCTAssertTrue(prefs.callNotifications)
        XCTAssertFalse(prefs.groupNotifications)
        XCTAssertFalse(prefs.showPreviews)
        XCTAssertFalse(prefs.vibrateEnabled)
    }

    /// The regression that motivated this: a user who turned notifications off
    /// saw them rendered as on when reopening the screen.
    func testDisabledPreferencesSurviveAReload() {
        let prefs = NotificationPreferences(
            from: settings(message: false, call: false, group: false)
        )
        XCTAssertFalse(prefs.messageNotifications)
        XCTAssertFalse(prefs.callNotifications)
        XCTAssertFalse(prefs.groupNotifications)
    }

    /// One stored string carries both "which tone" and "sound on at all".
    func testSilentSentinelTurnsSoundOff() {
        let prefs = NotificationPreferences(from: settings(sound: "none"))
        XCTAssertFalse(prefs.soundEnabled)
        XCTAssertEqual(prefs.notificationSound, "", "the sentinel must not leak into the tone name")
    }

    func testNamedToneKeepsSoundOn() {
        let prefs = NotificationPreferences(from: settings(sound: "chime"))
        XCTAssertTrue(prefs.soundEnabled)
        XCTAssertEqual(prefs.notificationSound, "chime")
    }

    /// Empty means "default tone", not "silent" — the two are distinct and an
    /// empty string must not read as sound-off.
    func testEmptyToneStillMeansSoundOn() {
        let prefs = NotificationPreferences(from: settings(sound: ""))
        XCTAssertTrue(prefs.soundEnabled)
        XCTAssertEqual(prefs.notificationSound, "")
    }

    /// Decoding what the screen writes must return the same state, or a
    /// save-then-reopen would drift.
    func testSoundRoundTrips() {
        for (enabled, tone) in [(true, "chime"), (true, ""), (false, "chime")] {
            let stored = enabled ? tone : NotificationPreferences.silentSoundToken
            let prefs = NotificationPreferences(from: settings(sound: stored))
            XCTAssertEqual(prefs.soundEnabled, enabled, "sound flag drifted for \(stored)")
            if enabled {
                XCTAssertEqual(prefs.notificationSound, tone)
            }
        }
    }
}
