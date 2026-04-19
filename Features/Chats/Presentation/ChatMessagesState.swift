import Foundation
import SanchrShared

// MARK: - ChatMessagesState
// Concern-specific @Observable store carved out of ChatDetailViewModel as part
// of the Phase-1 split to reduce SwiftUI body re-evaluation cascades in the
// chat detail screen. Any view that only needs transcript-related state should
// subscribe to THIS store rather than the monolithic `ChatDetailViewModel`,
// so mutations to unrelated concerns (composer, presence, search) don't
// invalidate the transcript view.

@Observable
@MainActor
final class ChatMessagesState {
    /// Flat list of messages currently visible in the transcript.
    /// `didSet` keeps the O(1) `messagesById` lookup in sync.
    var messages: [Message] = [] {
        didSet { refreshMessagesLookup() }
    }

    /// O(1) message lookup by ID. Kept in sync with `messages` via
    /// `refreshMessagesLookup()` (called from the `didSet` on messages).
    /// Replaces O(n) linear scans through `messages.first(where:)` in hot
    /// paths like DocumentPreviewCoordinator's messageLookup closure.
    private(set) var messagesById: [String: Message] = [:]

    /// Grouped messages by day for stable section headers.
    var messageSections: [MessageSection] = [] {
        didSet { bumpTranscriptVersion() }
    }
    private(set) var transcriptVersion: UInt64 = 0

    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var hasMoreMessages: Bool = true

    /// ID of the first unread message on conversation entry. Drives the
    /// "New Messages" divider. Cleared when the user leaves the conversation.
    var firstUnreadMessageId: String?

    var lastPaginationAnchor: Date?

    /// Per-message upload progress + status, isolated in a dedicated
    /// @Observable store so byte-progress callbacks don't bump the
    /// transcript version (which would trigger a full snapshot reload).
    /// Consumers watch `uploads.version` for reconfigure-only updates.
    let uploads = UploadProgressStore()

    /// O(1) lookup by ID — preferred over `messages.first(where:)` in hot paths.
    func message(withId id: String) -> Message? {
        messagesById[id]
    }

    func bumpTranscriptVersion() {
        transcriptVersion &+= 1
    }

    /// Rebuilds the `messagesById` dict after every mutation of `messages`.
    private func refreshMessagesLookup() {
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }
}
