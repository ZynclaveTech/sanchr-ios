import Foundation
import UserNotifications

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
    var conversationInfo: Conversation?
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

    private var lastPaginationAnchor: Date?
    private var typingIdleTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var typingIndicatorIsActive = false

    // MARK: - Search State

    var isSearching = false
    var searchQuery = ""
    var searchResults: [Message] = []
    var currentSearchIndex = 0

    // MARK: - Conversation Lifecycle

    /// Called when the user enters a conversation.
    /// Clears any pending notifications for this conversation and sets the active conversation
    /// so that foreground notifications for it are suppressed.
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

    // MARK: - Reactions

    var showReactionPickerForMessageId: String?

    func toggleReaction(emoji: String, messageId: String, conversationId: String, userId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        if let reactionIndex = messages[index].reactions.firstIndex(where: { $0.emoji == emoji && $0.userId == userId }) {
            // Remove own reaction
            messages[index].reactions.remove(at: reactionIndex)
        } else {
            // Add reaction
            let reaction = Message.MessageReaction(
                emoji: emoji,
                userId: userId,
                timestamp: Date()
            )
            messages[index].reactions.append(reaction)
        }

        syncMessageSection(for: messages[index])
    }

    func handleRealtimeReaction(messageId: String, userId: String, emoji: String, removed: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        if removed {
            messages[index].reactions.removeAll { $0.emoji == emoji && $0.userId == userId }
        } else {
            let reaction = Message.MessageReaction(emoji: emoji, userId: userId, timestamp: Date())
            if !messages[index].reactions.contains(where: { $0.emoji == emoji && $0.userId == userId }) {
                messages[index].reactions.append(reaction)
            }
        }

        syncMessageSection(for: messages[index])
    }

    // MARK: - Reply State

    func setReply(to message: Message?) {
        replyingToMessage = message
    }

    func clearReply() {
        replyingToMessage = nil
    }

    // MARK: - Load Messages

    func loadMessages(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            messages = try await messageRepository.fetchMessages(
                conversationId: conversationId,
                before: nil,
                limit: 50
            )
            rebuildSections()
            hasMoreMessages = messages.count >= 50
            lastPaginationAnchor = nil
            SanchrLogger.chat.info(
                "Loaded \(self.messages.count) messages for \(conversationId.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to load messages: \(error.localizedDescription)")
        }
    }

    // MARK: - Send Message (E2EE)

    /// Encrypts the current input text via Signal Protocol and sends to the conversation.
    func sendMessage(
        conversationId: String,
        recipientId: String,
        messageRepository: MessageRepositoryProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        chatDataSource: ChatDataSource,
        localDatabase: LocalDatabaseProtocol,
        sessionService: SessionService
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input immediately for responsive UI
        inputText = ""
        clearReply()
        isSending = true

        // Optimistic UI: add message immediately with .sending status
        let optimisticMessage = Message.textMessage(
            conversationId: conversationId,
            senderId: sessionService.currentUserId ?? "unknown",
            text: text,
            isOutgoing: true
        )
        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)

        do {
            let useCase = ChatUseCases.SendMessageUseCase(
                signalSessionManager: signalProtocol,
                chatDataSource: chatDataSource,
                localDatabase: localDatabase,
                localUserId: sessionService.currentUserId ?? "unknown"
            )
            // Wrap in auth retry so UNAUTHENTICATED errors refresh the token and retry
            let sentMessage = try await sessionService.withAuthRetry {
                try await useCase.execute(
                    text: text,
                    conversationId: conversationId,
                    recipientId: recipientId
                )
            }
            // Replace optimistic message with server-confirmed message
            replaceMessage(id: optimisticMessage.id, with: sentMessage)
            SanchrLogger.chat.info("Message sent successfully")
        } catch {
            // Mark optimistic message as failed
            updateMessage(id: optimisticMessage.id) { $0.status = .failed }
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Send failed: \(error.localizedDescription)")
        }

        isSending = false
    }

    // MARK: - Media Send

    func sendMediaMessage(
        localFileURL: URL,
        mimeType: String,
        contentType: Message.MessageContent,
        conversationId: String,
        recipientId: String,
        caption: String?,
        messageRepository: MessageRepositoryProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        chatDataSource: ChatDataSource,
        localDatabase: LocalDatabaseProtocol,
        sessionService: SessionService,
        mediaUploadManager: MediaUploadManager,
        mediaEncryption: MediaEncryptionProtocol
    ) async {
        let senderId = sessionService.currentUserId ?? "unknown"

        // Create optimistic message with local file URL
        let optimisticMessage = Message(
            id: UUID().uuidString,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: Date(),
            content: contentType,
            status: .sending,
            isOutgoing: true,
            replyToMessageId: replyingToMessage?.id
        )

        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)
        clearReply()

        // Queue upload task
        var uploadTask = MediaUploadTask(
            conversationId: conversationId,
            recipientId: recipientId,
            localFileURL: localFileURL,
            mimeType: mimeType,
            caption: caption,
            replyToMessageId: replyingToMessage?.id
        )
        uploadTask.optimisticMessageId = optimisticMessage.id

        // Wire progress updates
        let msgId = optimisticMessage.id
        mediaUploadManager.onTaskUpdate = { [weak self] task in
            guard task.optimisticMessageId == msgId else { return }
            Task { @MainActor [weak self] in
                switch task.state {
                case .encrypting:
                    self?.uploadStatusLabel[msgId] = "Encrypting..."
                    self?.uploadProgress[msgId] = 0.1
                case .uploading(let progress):
                    self?.uploadStatusLabel[msgId] = "Uploading..."
                    self?.uploadProgress[msgId] = 0.1 + progress * 0.7
                case .confirming:
                    self?.uploadStatusLabel[msgId] = "Confirming..."
                    self?.uploadProgress[msgId] = 0.85
                case .sendingMessage:
                    self?.uploadStatusLabel[msgId] = "Sending..."
                    self?.uploadProgress[msgId] = 0.95
                case .completed:
                    self?.uploadProgress.removeValue(forKey: msgId)
                    self?.uploadStatusLabel.removeValue(forKey: msgId)
                case .failed(let error, _):
                    self?.uploadStatusLabel[msgId] = "Failed"
                    self?.uploadProgress.removeValue(forKey: msgId)
                    SanchrLogger.media.error("Upload failed: \(error)")
                case .cancelled:
                    self?.uploadProgress.removeValue(forKey: msgId)
                    self?.uploadStatusLabel.removeValue(forKey: msgId)
                default:
                    break
                }
            }
        }

        uploadTask = await mediaUploadManager.enqueue(uploadTask)

        // Execute upload pipeline (runs even if user leaves screen)
        Task.detached { [weak self] in
            SanchrLogger.media.info("Starting upload pipeline for task \(uploadTask.id.prefix(8))")
            guard let completedTask = await mediaUploadManager.execute(uploadTask.id) else {
                SanchrLogger.media.error("Upload pipeline returned nil for task \(uploadTask.id.prefix(8))")
                return
            }
            SanchrLogger.media.info("Upload pipeline completed: state=\(String(describing: completedTask.state))")

            guard case .sendingMessage = completedTask.state,
                  let metadata = completedTask.encryptionMetadata,
                  let mediaId = completedTask.mediaId else {
                SanchrLogger.media.warning("Upload task not in sendingMessage state or missing data: state=\(String(describing: completedTask.state)), hasMetadata=\(completedTask.encryptionMetadata != nil), mediaId=\(completedTask.mediaId ?? "nil")")
                return
            }

            // Store mediaId as the URL — receiver will call GetDownloadUrl(mediaId) to get presigned GET URL
            let mediaIdURL = URL(string: "sanchr-media://\(mediaId)")!
            SanchrLogger.media.info("Building final message with mediaId: \(mediaId)")

            // Cache the sender's local file so we never re-download our own media
            let ext = completedTask.mimeType.contains("png") ? "png" : completedTask.mimeType.contains("video") ? "mp4" : "jpg"
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MediaMessages", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cachedFile = cacheDir.appendingPathComponent("\(optimisticMessage.id).\(ext)")
            try? FileManager.default.copyItem(at: completedTask.localFileURL, to: cachedFile)
            SanchrLogger.media.info("Cached sender's local file at \(cachedFile.lastPathComponent)")

            // Build attachment with mediaId URL + encryption keys
            let attachment = Message.MediaAttachment(
                url: mediaIdURL,
                encryptionKey: metadata.key,
                encryptionIV: metadata.nonce,
                mimeType: completedTask.mimeType,
                sizeBytes: metadata.fileSize,
                thumbnailURL: nil,
                caption: completedTask.caption
            )

            // Create message with final attachment
            let finalMessage = Message(
                id: optimisticMessage.id,
                conversationId: conversationId,
                senderId: senderId,
                timestamp: Date(),
                content: Self.contentForAttachment(attachment, mimeType: completedTask.mimeType),
                status: .sending,
                isOutgoing: true,
                replyToMessageId: completedTask.replyToMessageId
            )

            // Send via Signal Protocol E2EE (use recipientId, not conversationId)
            do {
                let plaintext = try JSONEncoder().encode(finalMessage.content)
                let contentType = completedTask.mimeType.hasPrefix("image/") ? "image"
                    : completedTask.mimeType.hasPrefix("video/") ? "video"
                    : completedTask.mimeType.hasPrefix("audio/") ? "audio"
                    : "document"

                let response = try await chatDataSource.sendEncryptedMessage(
                    conversationId: conversationId,
                    plaintext: plaintext,
                    recipientIds: [recipientId],
                    signalSessionManager: signalProtocol,
                    contentType: contentType
                )

                let serverTimestamp = Date(timeIntervalSince1970: TimeInterval(response.serverTimestamp) / 1000.0)
                let sentMessage = Message(
                    id: response.messageID.isEmpty ? finalMessage.id : response.messageID,
                    conversationId: conversationId,
                    senderId: senderId,
                    timestamp: serverTimestamp,
                    content: finalMessage.content,
                    status: .sent,
                    isOutgoing: true,
                    replyToMessageId: finalMessage.replyToMessageId
                )

                try? await localDatabase.saveMessage(sentMessage)
                await mediaUploadManager.markCompleted(uploadTask.id)
                SanchrLogger.media.info("Media message sent: \(sentMessage.id)")

                await MainActor.run {
                    if let self {
                        self.replaceMessage(id: optimisticMessage.id, with: sentMessage)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.updateMessage(id: optimisticMessage.id) { $0.status = .failed }
                }
                SanchrLogger.chat.error("Media message send failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func contentForAttachment(_ attachment: Message.MediaAttachment, mimeType: String) -> Message.MessageContent {
        if mimeType.hasPrefix("image/") { return .image(attachment) }
        if mimeType.hasPrefix("video/") { return .video(attachment) }
        if mimeType.hasPrefix("audio/") { return .audio(attachment) }
        return .document(attachment)
    }

    // MARK: - Receive & Decrypt Incoming Message

    /// Decrypts an incoming encrypted envelope and appends the plaintext message to the list.
    func handleIncomingEnvelope(
        _ envelope: Vync_Messaging_EncryptedEnvelope,
        signalProtocol: SignalProtocolManagerProtocol
    ) async {
        do {
            let plaintext = try await signalProtocol.decryptEnvelope(envelope)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                SanchrLogger.chat.error("Failed to decode decrypted plaintext as UTF-8")
                return
            }

            let incomingMessage = Message(
                id: envelope.messageID,
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(envelope.serverTimestamp) / 1000),
                content: .text(text),
                status: .delivered,
                isOutgoing: false
            )
            appendMessageChronologically(incomingMessage)
            SanchrLogger.chat.info(
                "Decrypted and displayed incoming message \(envelope.messageID.prefix(8))")
        } catch {
            SanchrLogger.chat.error(
                "Failed to decrypt incoming message: \(error.localizedDescription)")
            // Insert a system message indicating decryption failure
            let errorMsg = Message(
                id: envelope.messageID,
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(envelope.serverTimestamp) / 1000),
                content: .system(.identityKeyChanged),
                status: .delivered,
                isOutgoing: false
            )
            appendMessageChronologically(errorMsg)
        }
    }

    // MARK: - Load More (Pagination)

    /// Loads older messages for infinite scroll.
    func loadMore(conversationId: String, messageRepository: MessageRepositoryProtocol) async {
        guard !isLoadingMore, hasMoreMessages, let oldest = messages.first else { return }
        guard lastPaginationAnchor != oldest.timestamp else { return }
        isLoadingMore = true
        lastPaginationAnchor = oldest.timestamp

        defer { isLoadingMore = false }

        do {
            let olderMessages = try await messageRepository.fetchMessages(
                conversationId: conversationId,
                before: oldest.timestamp,
                limit: 30
            )
            if olderMessages.isEmpty {
                hasMoreMessages = false
            } else {
                let existingIds = Set(messages.map(\.id))
                let deduped = olderMessages.filter { !existingIds.contains($0.id) }
                messages.insert(contentsOf: deduped, at: 0)
                rebuildSections()
            }
        } catch {
            SanchrLogger.chat.error("Load more failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Retry Failed Message

    func retryMessage(
        _ message: Message,
        recipientId: String,
        messageRepository: MessageRepositoryProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        chatDataSource: ChatDataSource,
        localDatabase: LocalDatabaseProtocol,
        sessionService: SessionService
    ) async {
        guard message.status == .failed, case .text(let text) = message.content else { return }

        // Remove the failed message
        messages.removeAll { $0.id == message.id }
        rebuildSections()

        // Re-send
        inputText = text
        await sendMessage(
            conversationId: message.conversationId,
            recipientId: recipientId,
            messageRepository: messageRepository,
            signalProtocol: signalProtocol,
            chatDataSource: chatDataSource,
            localDatabase: localDatabase,
            sessionService: sessionService
        )
    }

    // MARK: - Delete Message

    func deleteMessage(
        _ message: Message,
        forEveryone: Bool,
        messageRepository: MessageRepositoryProtocol,
        chatDataSource: ChatDataSource
    ) async {
        do {
            if forEveryone {
                try await chatDataSource.deleteMessage(
                    conversationID: message.conversationId,
                    messageID: message.id
                )
            }
            try await messageRepository.deleteMessage(id: message.id, forEveryone: forEveryone)
            messages.removeAll { $0.id == message.id }
            rebuildSections()
            SanchrLogger.chat.info("Deleted message \(message.id.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Typing Indicator

    func sendTypingIndicator(
        conversationId: String,
        isTyping: Bool,
        messageRepository: MessageRepositoryProtocol,
        canSend: Bool
    ) async {
        guard canSend else { return }
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
        messageRepository: MessageRepositoryProtocol,
        canSend: Bool
    ) {
        typingIdleTask?.cancel()
        let hasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasText else {
            Task {
                await stopTypingIndicator(
                    conversationId: conversationId,
                    messageRepository: messageRepository,
                    canSend: canSend
                )
            }
            return
        }

        if !typingIndicatorIsActive {
            Task {
                await setTypingIndicator(
                    true,
                    conversationId: conversationId,
                    messageRepository: messageRepository,
                    canSend: canSend
                )
            }
        }

        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.stopTypingIndicator(
                conversationId: conversationId,
                messageRepository: messageRepository,
                canSend: canSend
            )
        }
    }

    func stopTypingIndicator(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol,
        canSend: Bool
    ) async {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        await setTypingIndicator(
            false,
            conversationId: conversationId,
            messageRepository: messageRepository,
            canSend: canSend
        )
    }

    func handleRealtimeMessage(_ message: Message) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        appendMessageChronologically(message)
    }

    func handleTypingIndicator(_ indicator: Vync_Messaging_TypingIndicator) {
        guard showsTypingIndicators else {
            peerIsTyping = false
            peerTypingName = ""
            return
        }

        peerIsTyping = indicator.isTyping
        peerTypingName = indicator.userID
    }

    func handlePresenceUpdate(_ update: Vync_Messaging_PresenceUpdate, participantId: String?) {
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

    func handleReceipt(_ receipt: Vync_Messaging_ReceiptUpdate) {
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
        messageRepository: MessageRepositoryProtocol,
        canSend: Bool
    ) async {
        guard typingIndicatorIsActive != isTyping else { return }
        typingIndicatorIsActive = isTyping
        await sendTypingIndicator(
            conversationId: conversationId,
            isTyping: isTyping,
            messageRepository: messageRepository,
            canSend: canSend
        )
    }

    private func updateMessage(id: String, mutate: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messages[index].timestamp
        mutate(&messages[index])
        syncMessageSection(for: messages[index], previousTimestamp: previousTimestamp)
    }

    private func replaceMessage(id: String, with message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messages[index].timestamp
        messages[index] = message
        syncMessageSection(for: message, previousTimestamp: previousTimestamp)
    }

    private func appendMessageChronologically(_ message: Message) {
        if let lastMessage = messages.last, message.timestamp < lastMessage.timestamp {
            messages.append(message)
            messages.sort { $0.timestamp < $1.timestamp }
            rebuildSections()
            return
        }

        messages.append(message)
        appendMessageToSections(message)
    }

    private func appendMessageToSections(_ message: Message) {
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

    private func syncMessageSection(for message: Message, previousTimestamp: Date? = nil) {
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

    private func rebuildSections() {
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
