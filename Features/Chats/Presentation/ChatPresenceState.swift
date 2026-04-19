import Foundation
import SanchrShared

// MARK: - ChatPresenceState
// Concern-specific @Observable store for peer presence + typing indicator
// state. Owned by `ChatDetailViewModel` and injected into
// `ChatDetailHeaderView` so the transcript + composer don't re-evaluate
// every time a realtime presence/typing event arrives.

@Observable
@MainActor
final class ChatPresenceState {
    var peerIsTyping: Bool = false
    var peerTypingName: String = ""
    var peerPresenceStatus: User.Status = .offline
    var peerLastSeen: Date?
    var peerPresenceHidden: Bool = false
    var showsPresence: Bool = false
    var showsTypingIndicators: Bool = false

    /// Debounce task handles for the self-typing-indicator lifecycle +
    /// the peer-typing-auto-clear timer. Previously stored on the
    /// monolithic ChatDetailViewModel; moved here because the extension
    /// methods that drive them already live in the Realtime feature area.
    var typingIdleTask: Task<Void, Never>?
    var peerTypingClearTask: Task<Void, Never>?
    var typingIndicatorIsActive: Bool = false
}
