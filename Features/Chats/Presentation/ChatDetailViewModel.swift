import Foundation
import UserNotifications

struct MessageSection: Identifiable, Sendable {
    let id: Date
    let title: String
    let messages: [Message]
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

    /// Whether the peer is typing.
    var peerIsTyping: Bool = false
    var peerTypingName: String = ""

    /// Grouped messages by day for stable section headers.
    private(set) var messageSections: [MessageSection] = []

    /// Whether there are more messages to load.
    var hasMoreMessages: Bool = true

    private var lastPaginationAnchor: Date?

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
        sessionService: SessionService
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input immediately for responsive UI
        inputText = ""
        isSending = true

        // Optimistic UI: add message immediately with .sending status
        let optimisticMessage = Message.textMessage(
            conversationId: conversationId,
            senderId: sessionService.currentUserId ?? "unknown",
            text: text,
            isOutgoing: true
        )
        messages.append(optimisticMessage)
        rebuildSections()

        do {
            let useCase = ChatUseCases.SendMessageUseCase(
                messageRepository: messageRepository,
                signalSessionManager: signalProtocol,
                chatDataSource: chatDataSource,
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
            if let index = messages.firstIndex(where: { $0.id == optimisticMessage.id }) {
                messages[index] = sentMessage
            }
            rebuildSections()
            SanchrLogger.chat.info("Message sent successfully")
        } catch {
            // Mark optimistic message as failed
            if let index = messages.firstIndex(where: { $0.id == optimisticMessage.id }) {
                messages[index].status = .failed
            }
            rebuildSections()
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Send failed: \(error.localizedDescription)")
        }

        isSending = false
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
            messages.append(incomingMessage)
            rebuildSections()
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
            messages.append(errorMsg)
            rebuildSections()
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

    func handleRealtimeMessage(_ message: Message) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        messages.sort { $0.timestamp < $1.timestamp }
        rebuildSections()
    }

    func handleTypingIndicator(_ indicator: Vync_Messaging_TypingIndicator) {
        peerIsTyping = indicator.isTyping
        peerTypingName = indicator.userID
    }

    func handleReceipt(_ receipt: Vync_Messaging_ReceiptUpdate) {
        guard let index = messages.firstIndex(where: { $0.id == receipt.messageID }) else { return }
        if let status = Message.DeliveryStatus(rawValue: receipt.status) {
            messages[index].status = status
            rebuildSections()
        }
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
}
