import Foundation
import SanchrShared

struct MessageSection: Identifiable, Sendable {
    let id: Date
    let title: String
    var messages: [Message]
}

/// View model for the chat conversation detail screen.
/// Manages messages, input, sending, optimistic updates, and pagination.
/// All outgoing messages are encrypted via Signal Protocol before sending.
/// Incoming messages are decrypted before display.
@MainActor
@Observable
final class ChatDetailViewModel {

    // MARK: - State

    var messages: [Message] = [] {
        didSet { refreshMessagesLookup() }
    }
    /// O(1) message lookup by ID. Kept in sync with `messages` via
    /// `refreshMessagesLookup()` (called from every mutation path).
    /// Replaces O(n) linear scans through `messages.first(where:)` in
    /// hot paths like DocumentPreviewCoordinator's messageLookup closure.
    private(set) var messagesById: [String: Message] = [:]
    var inputText: String = ""
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var isSending: Bool = false
    var errorMessage: String?
    var isTyping: Bool = false

    /// Message being replied to (shown as quote in composer)
    var replyingToMessage: Message?

    /// Per-message upload progress + status, isolated in a dedicated
    /// @Observable store so byte-progress callbacks don't bump the
    /// transcript version (which would trigger a full snapshot reload).
    /// Consumers watch `uploads.version` for reconfigure-only updates.
    let uploads = UploadProgressStore()

    /// Whether the peer is typing.
    var peerIsTyping: Bool = false
    var peerTypingName: String = ""
    var peerPresenceStatus: User.Status = .offline
    var peerLastSeen: Date?
    var peerPresenceHidden: Bool = false
    var showsPresence: Bool = false
    var showsTypingIndicators: Bool = false

    /// Grouped messages by day for stable section headers.
    private(set) var messageSections: [MessageSection] = [] {
        didSet { bumpTranscriptVersion() }
    }
    private(set) var transcriptVersion: UInt64 = 0

    /// Whether there are more messages to load.
    var hasMoreMessages: Bool = true

    /// ID of the first unread message on conversation entry.
    /// Drives the "New Messages" divider in the transcript.
    /// Cleared when the user leaves the conversation.
    var firstUnreadMessageId: String?

    var lastPaginationAnchor: Date?
    // Promoted to internal: accessed from ChatDetailViewModel+Realtime.swift
    var typingIdleTask: Task<Void, Never>?
    var peerTypingClearTask: Task<Void, Never>?
    // Promoted to internal: accessed from ChatDetailViewModel+Search.swift
    var searchTask: Task<Void, Never>?
    // Promoted to internal: accessed from ChatDetailViewModel+Realtime.swift
    var typingIndicatorIsActive = false

    // MARK: - Search State

    var isSearching = false
    var searchQuery = ""
    var searchResults: [Message] = []
    var currentSearchIndex = 0

    // MARK: - Bubble-tap routing

    /// Most recent interaction routed through `route(interaction:)`.
    /// Visible to tests only — the real app reads the coordinators bound
    /// in `ChatDetailView`, not this. Kept because it's the cheapest way
    /// to unit-test routing without coupling the test to the coordinator
    /// implementations (which live in the main-app target).
    var lastRoutedInteraction: MessageInteraction?

    /// Dispatch a bubble-tap interaction to the appropriate coordinator.
    /// Each handler is supplied by `ChatDetailView` because the coordinators
    /// themselves are `@StateObject`s that must live in the view hierarchy;
    /// the view model stays `@Observable` without holding `ObservableObject`
    /// references.
    ///
    /// For `.openMedia`, the method also seeds the gallery with every
    /// image/video message from the current in-memory snapshot in
    /// chronological order via `galleryItems(forTappedMessageId:)`.
    func route(
        interaction: MessageInteraction,
        onOpenGallery: (GallerySeed) -> Void = { _ in },
        onOpenContact: (String, String) -> Void = { _, _ in },
        onOpenLocation: (Double, Double) -> Void = { _, _ in },
        onOpenDocument: (String) -> Void = { _ in }
    ) {
        lastRoutedInteraction = interaction
        switch interaction {
        case .openMedia(let messageId):
            guard let seed = galleryItems(forTappedMessageId: messageId) else {
                SanchrLogger.chat.warning(
                    "route: no gallery seed for \(messageId.prefix(8))")
                return
            }
            onOpenGallery(seed)
        case .openContact(let name, let phoneNumber):
            onOpenContact(name, phoneNumber)
        case .openLocation(let latitude, let longitude):
            onOpenLocation(latitude, longitude)
        case .openDocument(let messageId):
            onOpenDocument(messageId)
        }
    }

    /// Seed the media gallery with every image + video in the current chat
    /// snapshot, ordered chronologically, plus the tapped message's index.
    /// Returns `nil` if the tapped message isn't media or isn't in the
    /// current snapshot. The snapshot is frozen at call time — new messages
    /// arriving while the gallery is open do NOT mutate the pager.
    func galleryItems(forTappedMessageId messageId: String) -> GallerySeed? {
        let ordered = messages
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image:
                    return GalleryItem(id: msg.id, kind: .image, message: msg)
                case .video:
                    return GalleryItem(id: msg.id, kind: .video, message: msg)
                default:
                    return nil
                }
            }
        guard let index = ordered.firstIndex(where: { $0.id == messageId }) else {
            return nil
        }
        return GallerySeed(items: ordered, initialIndex: index)
    }

    // MARK: - Conversation Lifecycle

    @MainActor
    func onConversationAppear(conversationId: String, pushManager: PushManager) {
        pushManager.setActiveConversation(conversationId)

        // Clear delivered notifications for this conversation
        SanchrNotificationService.clearNotifications(for: conversationId)

        SanchrLogger.chat.info(
            "Entered conversation \(conversationId.prefix(8))..., notifications cleared")
    }

    /// Called when the user leaves a conversation.
    @MainActor
    func onConversationDisappear(pushManager: PushManager) {
        pushManager.setActiveConversation(nil)
        firstUnreadMessageId = nil
    }

    func configurePeer(
        _ peer: User?,
        showsPresence: Bool? = nil,
        showsTypingIndicators: Bool? = nil
    ) {
        if let showsPresence {
            self.showsPresence = showsPresence
        }
        if let showsTypingIndicators {
            self.showsTypingIndicators = showsTypingIndicators
        }

        guard let peer else { return }
        peerPresenceStatus = peer.status
        peerLastSeen = peer.lastSeen
        peerPresenceHidden = false
    }

    // MARK: - Typing Indicator / Realtime
    // Extracted to ChatDetailViewModel+Realtime.swift

    // MARK: - Search
    // Extracted to ChatDetailViewModel+Search.swift

    func updateMessage(id: String, mutate: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messages[index].timestamp
        mutate(&messages[index])
        syncMessageSection(for: messages[index], previousTimestamp: previousTimestamp)
    }

    func replaceMessage(id: String, with message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messages[index].timestamp
        messages[index] = message
        syncMessageSection(for: message, previousTimestamp: previousTimestamp)
    }

    func appendMessageChronologically(_ message: Message) {
        if let lastMessage = messages.last, message.timestamp < lastMessage.timestamp {
            messages.append(message)
            messages.sort { $0.timestamp < $1.timestamp }
            rebuildSections()
            return
        }

        messages.append(message)
        appendMessageToSections(message)
    }

    func appendMessageToSections(_ message: Message) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: message.timestamp)

        if let lastIndex = messageSections.indices.last {
            if messageSections[lastIndex].id == day {
                messageSections[lastIndex].messages.append(message)
                return
            }

            if messageSections[lastIndex].id < day {
                messageSections.append(
                    MessageSection(
                        id: day,
                        title: sectionTitle(for: day, calendar: calendar),
                        messages: [message]
                    )
                )
                return
            }
        }

        if messageSections.isEmpty {
            messageSections = [
                MessageSection(
                    id: day,
                    title: sectionTitle(for: day, calendar: calendar),
                    messages: [message]
                )
            ]
            return
        }

        rebuildSections()
    }

    func syncMessageSection(for message: Message, previousTimestamp: Date? = nil) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: message.timestamp)

        if let previousTimestamp,
           calendar.startOfDay(for: previousTimestamp) != day
        {
            rebuildSections()
            return
        }

        guard let sectionIndex = messageSections.firstIndex(where: { $0.id == day }),
              let messageIndex = messageSections[sectionIndex].messages.firstIndex(where: {
                  $0.id == message.id
              })
        else {
            rebuildSections()
            return
        }

        messageSections[sectionIndex].messages[messageIndex] = message
    }

    func rebuildSections() {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: messages) { message in
            calendar.startOfDay(for: message.timestamp)
        }

        messageSections = grouped
            .map { day, messages in
                MessageSection(
                    id: day,
                    title: sectionTitle(for: day, calendar: calendar),
                    messages: messages.sorted { $0.timestamp < $1.timestamp }
                )
            }
            .sorted { $0.id < $1.id }
    }

    private func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func bumpTranscriptVersion() {
        transcriptVersion &+= 1
    }

    /// Rebuilds the `messagesById` dict after every mutation of `messages`.
    /// Wired via `didSet` on `messages` so every append / replace / remove /
    /// reassignment keeps the lookup dict authoritative.
    private func refreshMessagesLookup() {
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }

    /// O(1) lookup by ID — preferred over `messages.first(where:)` in hot paths.
    func message(withId id: String) -> Message? {
        messagesById[id]
    }
}

// MARK: - Gallery DTOs

/// Frozen gallery page list + starting index produced by
/// `ChatDetailViewModel.galleryItems(forTappedMessageId:)` and consumed by
/// `MediaGalleryCoordinator` (added in Phase 2).
struct GallerySeed: Equatable {
    let items: [GalleryItem]
    let initialIndex: Int
}

struct GalleryItem: Identifiable, Equatable {
    enum Kind: Equatable { case image, video }
    let id: String            // messageId
    let kind: Kind
    let message: Message
}
