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
///
/// This class is a thin composition root: the 32 stored properties that used
/// to live here have been split into four concern-specific @Observable
/// sub-stores (`messagesState`, `inputState`, `presenceState`, `searchState`)
/// so views can subscribe to only the surface they actually read. Proxy
/// properties are retained for back-compat with callers that still reach
/// through the view model — remove them once every view has been narrowed.
@MainActor
@Observable
final class ChatDetailViewModel {

    // MARK: - Sub-stores

    let messagesState: ChatMessagesState
    let inputState: ChatInputState
    let presenceState: ChatPresenceState
    let searchState: ChatSearchState

    init(
        messagesState: ChatMessagesState = ChatMessagesState(),
        inputState: ChatInputState = ChatInputState(),
        presenceState: ChatPresenceState = ChatPresenceState(),
        searchState: ChatSearchState = ChatSearchState()
    ) {
        self.messagesState = messagesState
        self.inputState = inputState
        self.presenceState = presenceState
        self.searchState = searchState
    }

    // MARK: - Back-compat proxy properties (remove after all views narrow)
    //
    // These keep existing call sites in views + tests working while we
    // migrate one subscription at a time. Each getter reads through to the
    // matching sub-store; each setter writes back. There is NO extra
    // observation overhead — reading `viewModel.messages` bumps the same
    // track as reading `viewModel.messagesState.messages` because
    // @Observable tracks keypaths on the concrete storage.

    var messages: [Message] {
        get { messagesState.messages }
        set { messagesState.messages = newValue }
    }
    var messagesById: [String: Message] { messagesState.messagesById }
    var messageSections: [MessageSection] {
        get { messagesState.messageSections }
        set { messagesState.messageSections = newValue }
    }
    var transcriptVersion: UInt64 { messagesState.transcriptVersion }
    var isLoading: Bool {
        get { messagesState.isLoading }
        set { messagesState.isLoading = newValue }
    }
    var isLoadingMore: Bool {
        get { messagesState.isLoadingMore }
        set { messagesState.isLoadingMore = newValue }
    }
    var hasMoreMessages: Bool {
        get { messagesState.hasMoreMessages }
        set { messagesState.hasMoreMessages = newValue }
    }
    var firstUnreadMessageId: String? {
        get { messagesState.firstUnreadMessageId }
        set { messagesState.firstUnreadMessageId = newValue }
    }
    var lastPaginationAnchor: Date? {
        get { messagesState.lastPaginationAnchor }
        set { messagesState.lastPaginationAnchor = newValue }
    }
    var uploads: UploadProgressStore { messagesState.uploads }

    var inputText: String {
        get { inputState.inputText }
        set { inputState.inputText = newValue }
    }
    var isSending: Bool {
        get { inputState.isSending }
        set { inputState.isSending = newValue }
    }
    var isTyping: Bool {
        get { inputState.isTyping }
        set { inputState.isTyping = newValue }
    }
    var replyingToMessage: Message? {
        get { inputState.replyingToMessage }
        set { inputState.replyingToMessage = newValue }
    }
    var errorMessage: String? {
        get { inputState.errorMessage }
        set { inputState.errorMessage = newValue }
    }

    var peerIsTyping: Bool {
        get { presenceState.peerIsTyping }
        set { presenceState.peerIsTyping = newValue }
    }
    var peerTypingName: String {
        get { presenceState.peerTypingName }
        set { presenceState.peerTypingName = newValue }
    }
    var peerPresenceStatus: User.Status {
        get { presenceState.peerPresenceStatus }
        set { presenceState.peerPresenceStatus = newValue }
    }
    var peerLastSeen: Date? {
        get { presenceState.peerLastSeen }
        set { presenceState.peerLastSeen = newValue }
    }
    var peerPresenceHidden: Bool {
        get { presenceState.peerPresenceHidden }
        set { presenceState.peerPresenceHidden = newValue }
    }
    var showsPresence: Bool {
        get { presenceState.showsPresence }
        set { presenceState.showsPresence = newValue }
    }
    var showsTypingIndicators: Bool {
        get { presenceState.showsTypingIndicators }
        set { presenceState.showsTypingIndicators = newValue }
    }
    var typingIdleTask: Task<Void, Never>? {
        get { presenceState.typingIdleTask }
        set { presenceState.typingIdleTask = newValue }
    }
    var peerTypingClearTask: Task<Void, Never>? {
        get { presenceState.peerTypingClearTask }
        set { presenceState.peerTypingClearTask = newValue }
    }
    var typingIndicatorIsActive: Bool {
        get { presenceState.typingIndicatorIsActive }
        set { presenceState.typingIndicatorIsActive = newValue }
    }

    var isSearching: Bool {
        get { searchState.isSearching }
        set { searchState.isSearching = newValue }
    }
    var searchQuery: String {
        get { searchState.searchQuery }
        set { searchState.searchQuery = newValue }
    }
    var searchResults: [Message] {
        get { searchState.searchResults }
        set { searchState.searchResults = newValue }
    }
    var currentSearchIndex: Int {
        get { searchState.currentSearchIndex }
        set { searchState.currentSearchIndex = newValue }
    }
    var searchTask: Task<Void, Never>? {
        get { searchState.searchTask }
        set { searchState.searchTask = newValue }
    }
    var currentSearchResultId: String? { searchState.currentSearchResultId }

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
        onOpenDocument: (String) -> Void = { _ in },
        onToggleReaction: (String, String) -> Void = { _, _ in }
    ) {
        lastRoutedInteraction = interaction
        switch interaction {
        case .openMedia(let messageId, let attachmentIndex):
            guard let seed = galleryItems(
                forTappedMessageId: messageId,
                attachmentIndex: attachmentIndex
            ) else {
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
        case .toggleReaction(let messageId, let emoji):
            onToggleReaction(messageId, emoji)
        }
    }

    /// Seed the media gallery with the tapped message's own attachments.
    ///
    /// Scoped to one message on purpose. Paging the whole conversation's media
    /// meant opening one photo and finding yourself swiping through everything
    /// ever sent, with no sense of where the album ended — and the thumbnail
    /// strip made that worse by suggesting all of it belonged together. The
    /// browse-everything view already exists separately under shared content.
    ///
    /// Returns `nil` if the message is not media or is not in the current
    /// snapshot. The snapshot is frozen at call time, so messages arriving
    /// while the gallery is open do not mutate the pager.
    func galleryItems(
        forTappedMessageId messageId: String,
        attachmentIndex: Int = 0
    ) -> GallerySeed? {
        guard let message = messagesState.messages.first(where: { $0.id == messageId })
        else { return nil }

        let media: Message.MediaAttachments
        let kind: GalleryItem.Kind
        switch message.content {
        case .image(let m): media = m; kind = .image
        case .video(let m): media = m; kind = .video
        default: return nil
        }
        guard !media.isEmpty else { return nil }

        let items = media.items.indices.map { index in
            GalleryItem(kind: kind, message: message, attachmentIndex: index)
        }
        // A stale index still opens the message rather than failing the tap.
        let initial = items.indices.contains(attachmentIndex) ? attachmentIndex : 0
        return GallerySeed(items: items, initialIndex: initial)
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
        messagesState.firstUnreadMessageId = nil
    }

    func configurePeer(
        _ peer: User?,
        showsPresence: Bool? = nil,
        showsTypingIndicators: Bool? = nil
    ) {
        if let showsPresence {
            presenceState.showsPresence = showsPresence
        }
        if let showsTypingIndicators {
            presenceState.showsTypingIndicators = showsTypingIndicators
        }

        guard let peer else { return }
        presenceState.peerPresenceStatus = peer.status
        presenceState.peerLastSeen = peer.lastSeen
        presenceState.peerPresenceHidden = false
    }

    // MARK: - Typing Indicator / Realtime
    // Extracted to ChatDetailViewModel+Realtime.swift

    // MARK: - Search
    // Extracted to ChatDetailViewModel+Search.swift

    func updateMessage(id: String, mutate: (inout Message) -> Void) {
        guard let index = messagesState.messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messagesState.messages[index].timestamp
        mutate(&messagesState.messages[index])
        syncMessageSection(for: messagesState.messages[index], previousTimestamp: previousTimestamp)
    }

    func replaceMessage(id: String, with message: Message) {
        guard let index = messagesState.messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messagesState.messages[index].timestamp
        messagesState.messages[index] = message
        syncMessageSection(for: message, previousTimestamp: previousTimestamp)
    }

    func appendMessageChronologically(_ message: Message) {
        if let lastMessage = messagesState.messages.last, message.timestamp < lastMessage.timestamp {
            messagesState.messages.append(message)
            messagesState.messages.sort { $0.timestamp < $1.timestamp }
            rebuildSections()
            return
        }

        messagesState.messages.append(message)
        appendMessageToSections(message)
    }

    func appendMessageToSections(_ message: Message) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: message.timestamp)

        if let lastIndex = messagesState.messageSections.indices.last {
            if messagesState.messageSections[lastIndex].id == day {
                messagesState.messageSections[lastIndex].messages.append(message)
                return
            }

            if messagesState.messageSections[lastIndex].id < day {
                messagesState.messageSections.append(
                    MessageSection(
                        id: day,
                        title: Self.sectionTitle(for: day, calendar: calendar),
                        messages: [message]
                    )
                )
                return
            }
        }

        if messagesState.messageSections.isEmpty {
            messagesState.messageSections = [
                MessageSection(
                    id: day,
                    title: Self.sectionTitle(for: day, calendar: calendar),
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

        guard let sectionIndex = messagesState.messageSections.firstIndex(where: { $0.id == day }),
              let messageIndex = messagesState.messageSections[sectionIndex].messages.firstIndex(where: {
                  $0.id == message.id
              })
        else {
            rebuildSections()
            return
        }

        messagesState.messageSections[sectionIndex].messages[messageIndex] = message
    }

    /// Groups the transcript into day sections.
    ///
    /// Runs on every message change — a new message, a status flip, a
    /// reaction — so its cost is paid constantly and scales with everything
    /// loaded. It used to build a `Dictionary(grouping:)` over the whole
    /// transcript, sort each day's messages, then sort the days: O(n log n)
    /// plus a dictionary and a fresh array per day, every time. On a long
    /// conversation scrolled well back that is thousands of messages regrouped
    /// to append one.
    ///
    /// `messages` is already ascending — loads arrive sorted, older pages are
    /// inserted at the front, and new messages go in chronologically — so a
    /// single pass that starts a section each time the day changes produces
    /// the same result with no dictionary, no sorting, and one allocation per
    /// section. `Sections.build` holds the pass so it can be tested directly.
    func rebuildSections() {
        messagesState.messageSections = Self.buildSections(
            from: messagesState.messages,
            calendar: Calendar.current
        )
    }

    /// Single ascending pass over `messages`, caching the current day's bounds.
    ///
    /// Measured rather than assumed: at 10,000 messages the dominant cost is
    /// not the grouping or the sorting — it is calling `Calendar.startOfDay`
    /// once per message. A first attempt that removed the dictionary and the
    /// sorts came out *slower*, because those were never the expensive part.
    ///
    /// Since the transcript is ascending, consecutive messages nearly always
    /// fall in the same day, so holding the current day's half-open range turns
    /// ten thousand calendar calls into roughly one per day present. Adding a
    /// day through the calendar rather than adding 86,400 seconds keeps this
    /// correct across daylight-saving transitions.
    ///
    /// A message outside the cached range simply opens a new section, so
    /// unordered input still files each message under its own day rather than
    /// the wrong header.
    static func buildSections(from messages: [Message], calendar: Calendar) -> [MessageSection] {
        var sections: [MessageSection] = []
        var currentDay: Date?
        var currentDayEnd: Date?
        var currentMessages: [Message] = []

        func flush() {
            guard let day = currentDay, !currentMessages.isEmpty else { return }
            sections.append(
                MessageSection(
                    id: day,
                    title: sectionTitle(for: day, calendar: calendar),
                    messages: currentMessages
                )
            )
            currentMessages = []
        }

        for message in messages {
            let timestamp = message.timestamp
            let isSameDay: Bool
            if let start = currentDay, let end = currentDayEnd {
                isSameDay = timestamp >= start && timestamp < end
            } else {
                isSameDay = false
            }

            if !isSameDay {
                flush()
                let start = calendar.startOfDay(for: timestamp)
                currentDay = start
                currentDayEnd = calendar.date(byAdding: .day, value: 1, to: start)
                    ?? start.addingTimeInterval(86_400)
            }
            currentMessages.append(message)
        }
        flush()

        return sections
    }

    static func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// O(1) lookup by ID — preferred over `messages.first(where:)` in hot paths.
    func message(withId id: String) -> Message? {
        messagesState.message(withId: id)
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

/// One page in the media viewer.
///
/// A page is one *attachment*, not one message: an album of four photos is
/// four pages. `id` therefore cannot be the message id alone, or the pager
/// would collapse an album into a single entry.
struct GalleryItem: Identifiable, Equatable {
    enum Kind: Equatable { case image, video }
    let id: String
    let kind: Kind
    let message: Message
    /// Which attachment of the message this page shows.
    let attachmentIndex: Int

    var messageId: String { message.id }

    init(id: String? = nil, kind: Kind, message: Message, attachmentIndex: Int = 0) {
        // Single-attachment messages keep the bare message id, so existing
        // callers and any persisted references stay stable.
        self.id = id ?? (attachmentIndex == 0 ? message.id : "\(message.id)#\(attachmentIndex)")
        self.kind = kind
        self.message = message
        self.attachmentIndex = attachmentIndex
    }

    /// The attachment this page renders, or nil if the message no longer holds
    /// one at that position.
    var attachment: Message.MediaAttachment? {
        switch message.content {
        case .image(let media), .video(let media), .audio(let media), .document(let media):
            return media.items.indices.contains(attachmentIndex)
                ? media.items[attachmentIndex] : nil
        default:
            return nil
        }
    }
}
