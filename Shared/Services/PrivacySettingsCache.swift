import Foundation
import OSLog

/// Thread-safe cached copy of user privacy settings.
/// Readable from any context. Updated after settings fetch/change.
final class PrivacySettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _readReceipts: Bool = true
    private var _typingIndicator: Bool = true
    private var _onlineStatusVisible: Bool = true
    private var _sanchrModeEnabled: Bool = false

    var canSendReadReceipts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _readReceipts && !_sanchrModeEnabled
    }

    var canSendTypingIndicators: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _typingIndicator && !_sanchrModeEnabled
    }

    var canSendPresence: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _onlineStatusVisible && !_sanchrModeEnabled
    }

    /// Update cache from server settings response. Safe to call from any thread.
    func update(from settings: Vync_Settings_UserSettings) {
        lock.lock()
        _readReceipts = settings.readReceipts
        _typingIndicator = settings.typingIndicator
        _onlineStatusVisible = settings.onlineStatusVisible
        _sanchrModeEnabled = settings.vyncModeEnabled
        lock.unlock()
        SanchrLogger.settings.info(
            "Privacy cache updated: rr=\(settings.readReceipts), ti=\(settings.typingIndicator), os=\(settings.onlineStatusVisible), vm=\(settings.vyncModeEnabled)"
        )
    }
}
