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

    var messages: [Message] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var isSending: Bool = false
    var errorMessage: String?
    var isTyping: Bool = false

    /// Message being replied to (shown as quote in composer)
    var replyingToMessage: Message?

    /// Upload progress per message ID (0.0 to 1.0). Removed when complete.
    var uploadProgress: [String: Double] = [:] {
        didSet { bumpTranscriptVersion() }
    }
    /// Upload status label per message ID
    var uploadStatusLabel: [String: String] = [:] {
        didSet { bumpTranscriptVersion() }
    }

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
    private var typingIdleTask: Task<Void, Never>?
    private var peerTypingClearTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var typingIndicatorIsActive = false

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

    // MARK: - Typing Indicator

    func sendTypingIndicator(
        conversationId: String,
        isTyping: Bool,
        messageRepository: MessageRepositoryProtocol
    ) async {
        do {
            try await messageRepository.sendTypingIndicator(
                conversationId: conversationId,
                isTyping: isTyping
            )
        } catch {
            // Typing indicator failures are non-critical
        }
    }

    func handleInputTextChanged(
        _ newValue: String,
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) {
        typingIdleTask?.cancel()
        let hasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasText else {
            Task {
                await stopTypingIndicator(
                    conversationId: conversationId,
                    messageRepository: messageRepository
                )
            }
            return
        }

        if !typingIndicatorIsActive {
            Task {
                await setTypingIndicator(
                    true,
                    conversationId: conversationId,
                    messageRepository: messageRepository
                )
            }
        }

        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.stopTypingIndicator(
                conversationId: conversationId,
                messageRepository: messageRepository
            )
        }
    }

    func stopTypingIndicator(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        await setTypingIndicator(
            false,
            conversationId: conversationId,
            messageRepository: messageRepository
        )
    }

    func handleRealtimeMessage(_ message: Message) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        appendMessageChronologically(message)
    }

    func handleTypingIndicator(_ indicator: Sanchr_Messaging_TypingIndicator) {
        peerTypingClearTask?.cancel()
        peerTypingClearTask = nil

        guard showsTypingIndicators else {
            peerIsTyping = false
            peerTypingName = ""
            return
        }

        peerIsTyping = indicator.isTyping
        peerTypingName = indicator.userID

        guard indicator.isTyping else { return }

        let userID = indicator.userID
        peerTypingClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.peerTypingName == userID else { return }
                self.peerIsTyping = false
                self.peerTypingName = ""
            }
        }
    }

    func handlePresenceUpdate(_ update: Sanchr_Messaging_PresenceUpdate, participantId: String?) {
        guard let participantId, update.userID == participantId else { return }

        switch update.statusCode {
        case .online:
            peerPresenceHidden = false
            peerPresenceStatus = .online
            peerLastSeen = nil

        case .hidden:
            peerPresenceHidden = true
            peerPresenceStatus = .offline
            peerLastSeen = nil

        case .offline, .unspecified, .UNRECOGNIZED:
            peerPresenceHidden = false
            peerPresenceStatus = .offline
            peerLastSeen = update.lastSeen > 0
                ? Date(timeIntervalSince1970: TimeInterval(update.lastSeen) / 1000)
                : nil
        }
    }

    func handleReceipt(_ receipt: Sanchr_Messaging_ReceiptUpdate) {
        guard let index = messages.firstIndex(where: { $0.id == receipt.messageID }) else { return }
        if let status = Message.DeliveryStatus(rawValue: receipt.status) {
            messages[index].status = status
            syncMessageSection(for: messages[index])
        }
    }

    // MARK: - Search

    func scheduleSearch(
        conversationId: String,
        query: String,
        localDatabase: LocalDatabaseProtocol
    ) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            currentSearchIndex = 0
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let results = try await localDatabase.searchMessages(
                    conversationId: conversationId,
                    query: query
                )

                await MainActor.run {
                    guard let self, self.searchQuery == query else { return }
                    self.searchResults = results
                    self.currentSearchIndex = 0
                }
            } catch {
                await MainActor.run {
                    guard let self, self.searchQuery == query else { return }
                    SanchrLogger.chat.error("Search failed: \(error.localizedDescription)")
                    self.searchResults = []
                }
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        currentSearchIndex = 0
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
    }

    var currentSearchResultId: String? {
        guard !searchResults.isEmpty else { return nil }
        return searchResults[currentSearchIndex].id
    }

    private func setTypingIndicator(
        _ isTyping: Bool,
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        guard typingIndicatorIsActive != isTyping else { return }
        typingIndicatorIsActive = isTyping
        await sendTypingIndicator(
            conversationId: conversationId,
            isTyping: isTyping,
            messageRepository: messageRepository
        )
    }

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
