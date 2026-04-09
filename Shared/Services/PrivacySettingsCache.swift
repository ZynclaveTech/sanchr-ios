import Foundation
import OSLog
import SanchrShared

/// Thread-safe cached copy of user privacy settings.
/// Readable from any context. Updated after settings fetch/change.
/// Cleared on logout via `SessionService.clearSessionState()`.
final class PrivacySettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _readReceipts: Bool = true
    private var _typingIndicator: Bool = true
    private var _onlineStatusVisible: Bool = true
    private var _sanchrModeEnabled: Bool = false
    private var _profilePhotoVisibility: String = "everyone"
    private var _blockedUserIds: Set<String> = []

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

    var profilePhotoVisibility: String {
        lock.lock()
        defer { lock.unlock() }
        return _profilePhotoVisibility
    }

    var blockedUserIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return _blockedUserIds
    }

    func isBlocked(_ userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _blockedUserIds.contains(userId)
    }

    /// Update cache from server settings response. Safe to call from any thread.
    func update(from settings: Vync_Settings_UserSettings) {
        lock.lock()
        _readReceipts = settings.readReceipts
        _typingIndicator = settings.typingIndicator
        _onlineStatusVisible = settings.onlineStatusVisible
        _sanchrModeEnabled = settings.vyncModeEnabled
        _profilePhotoVisibility = settings.profilePhotoVisibility.isEmpty
            ? "everyone"
            : settings.profilePhotoVisibility
        lock.unlock()
        SanchrLogger.settings.info(
            "Privacy cache updated: rr=\(settings.readReceipts), ti=\(settings.typingIndicator), os=\(settings.onlineStatusVisible), vm=\(settings.vyncModeEnabled), pp=\(settings.profilePhotoVisibility)"
        )
    }

    /// Updates the blocked-user set. Called after fetching the blocked list
    /// from ContactDataSource. Replaces the entire set atomically.
    func update(blockList: Set<String>) {
        lock.lock()
        _blockedUserIds = blockList
        lock.unlock()
        SanchrLogger.settings.info("Privacy cache blockList updated: count=\(blockList.count)")
    }

    /// Reset every field to its default. Called from
    /// `SessionService.clearSessionState()` so a logged-out session cannot
    /// leak the previous user's privacy state into a new login. Defaults are
    /// permissive (readReceipts/typing/presence on, sanchrMode off, profile
    /// photo visible to everyone, no blocks) to match Signal/WhatsApp
    /// cold-start conventions.
    func clear() {
        lock.lock()
        _readReceipts = true
        _typingIndicator = true
        _onlineStatusVisible = true
        _sanchrModeEnabled = false
        _profilePhotoVisibility = "everyone"
        _blockedUserIds = []
        lock.unlock()
        SanchrLogger.settings.info("Privacy cache cleared")
    }
}
