import Foundation
import SwiftUI

/// Thread-safe cached copy of user privacy settings.
/// Read synchronously from any context. Updated after settings fetch/change.
@MainActor
@Observable
final class PrivacySettingsCache {
    private(set) var readReceipts: Bool = true
    private(set) var typingIndicator: Bool = true
    private(set) var onlineStatusVisible: Bool = true
    private(set) var sanchrModeEnabled: Bool = false

    /// Effective privacy state accounting for Sanchr Mode override.
    var canSendReadReceipts: Bool {
        !sanchrModeEnabled && readReceipts
    }

    var canSendTypingIndicators: Bool {
        !sanchrModeEnabled && typingIndicator
    }

    var canSendPresence: Bool {
        !sanchrModeEnabled && onlineStatusVisible
    }

    /// Update cache from server settings response.
    func update(from settings: Vync_Settings_UserSettings) {
        readReceipts = settings.readReceipts
        typingIndicator = settings.typingIndicator
        onlineStatusVisible = settings.onlineStatusVisible
        sanchrModeEnabled = settings.vyncModeEnabled
        SanchrLogger.settings.info(
            "Privacy cache updated: readReceipts=\(self.readReceipts), typing=\(self.typingIndicator), presence=\(self.onlineStatusVisible), sanchrMode=\(self.sanchrModeEnabled)"
        )
    }
}
