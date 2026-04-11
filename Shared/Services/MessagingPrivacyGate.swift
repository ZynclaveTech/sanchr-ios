import Foundation
import SanchrShared

/// Narrow gate wrapper that decides whether a privacy-sensitive messaging
/// signal should be dispatched. `MessageRepositoryImpl` holds an instance
/// constructed from the injected PrivacySettingsCache and consults it from
/// markAsRead, sendTypingIndicator, and sealed P2P presence.
///
/// Separated from the repository so the decision logic can be unit-tested
/// in isolation. Instantiating the full MessageRepositoryImpl would require
/// ~100 stub methods across six concrete dependencies (including two actors
/// and one final class).
struct MessagingPrivacyGate: Sendable {
    let privacySettings: PrivacySettingsCache

    enum Signal: Sendable, Equatable {
        case readReceipt
        case typingIndicator
        case presence
    }

    enum Decision: Sendable, Equatable {
        case allow
        case suppress
    }

    enum PresenceDecision: Sendable, Equatable {
        case allow(Sanchr_Messaging_PresenceStatus)
        case suppress
    }

    func decide(_ signal: Signal) -> Decision {
        switch signal {
        case .readReceipt:
            return privacySettings.canSendReadReceipts ? .allow : .suppress
        case .typingIndicator:
            return privacySettings.canSendTypingIndicators ? .allow : .suppress
        case .presence:
            return privacySettings.canSendPresence ? .allow : .suppress
        }
    }

    func decidePresenceStatus(
        requested status: Sanchr_Messaging_PresenceStatus
    ) -> PresenceDecision {
        if privacySettings.sanchrModeEnabled {
            return .suppress
        }

        if !privacySettings.onlineStatusVisible {
            return .allow(.hidden)
        }

        return .allow(status)
    }
}
