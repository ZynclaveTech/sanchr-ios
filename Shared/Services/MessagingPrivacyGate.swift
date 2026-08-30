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

    /// Whether a decrypted message should be kept.
    ///
    /// Blocking is enforced on the server in `route_message`, keyed on the
    /// sender — which the server knows only for the standard path. A sealed
    /// message carries no sender the server can read; that is the point of
    /// sealed sending. So for 1:1 chats, which use sealed sending whenever it
    /// is available, the server cannot apply the block and this is the only
    /// place left that can. `isBlocked` existed for it and was called from
    /// nowhere, so a blocked contact could go on messaging you.
    func acceptsMessage(from senderId: String) -> Decision {
        privacySettings.isBlocked(senderId) ? .suppress : .allow
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
