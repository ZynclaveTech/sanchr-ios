import Foundation
import SanchrShared

// MARK: - ChatInputState
// Concern-specific @Observable store for the composer / send pipeline state.
// Owned by `ChatDetailViewModel` and injected into `ChatInputBarView` so the
// transcript view doesn't re-evaluate every time the user types a character.

@Observable
@MainActor
final class ChatInputState {
    var inputText: String = ""
    var isSending: Bool = false
    var isTyping: Bool = false

    /// Message being replied to (shown as quote in composer).
    var replyingToMessage: Message?

    /// User-facing error banner triggered by the send pipeline.
    /// Non-send error surfaces (typing-indicator failures, presence updates,
    /// etc.) are silent — see ChatDetailViewModel+Realtime.swift.
    var errorMessage: String?
}
