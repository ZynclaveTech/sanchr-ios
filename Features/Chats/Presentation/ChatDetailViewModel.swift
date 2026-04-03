import Foundation
import UserNotifications

/// View model for the chat conversation detail screen.
/// Manages messages, input, sending, optimistic updates, and pagination.
/// All outgoing messages are encrypted via Signal Protocol before sending.
/// Incoming messages are decrypted before display.
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

    /// Grouped messages by date for section headers.
    var groupedMessages: [(String, [Message])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: messages) { message in
            if calendar.isDateInToday(message.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(message.timestamp) {
                return "Yesterday"
            } else {
                return message.timestamp.formatted(date: .abbreviated, time: .omitted)
            }
        }
        return grouped.sorted { lhs, rhs in
            guard let lhsDate = lhs.value.first?.timestamp,
                let rhsDate = rhs.value.first?.timestamp
            else { return false }
            return lhsDate < rhsDate
        }
    }

    /// Whether there are more messages to load.
    var hasMoreMessages: Bool = true

    // MARK: - Conversation Lifecycle

    /// Called when the user enters a conversation.
    /// Clears any pending notifications for this conversation and sets the active conversation
    /// so that foreground notifications for it are suppressed.
    @MainActor
    func onConversationAppear(conversationId: String) {
        PushManager.activeConversationId = conversationId

        // Clear delivered notifications for this conversation
        SanchrNotificationService.clearNotifications(for: conversationId)

        // Decrement badge (best-effort; the server is the source of truth for badge count)
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let remainingCount = delivered.filter {
                $0.request.content.threadIdentifier != conversationId
            }.count
            await SanchrNotificationService.updateBadgeCount(remainingCount)
        }

        SanchrLogger.chat.info(
            "Entered conversation \(conversationId.prefix(8))..., notifications cleared")
    }

    /// Called when the user leaves a conversation.
    @MainActor
    func onConversationDisappear() {
        PushManager.activeConversationId = nil
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
            hasMoreMessages = messages.count >= 50
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
        chatDataSource: ChatDataSource
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input immediately for responsive UI
        inputText = ""
        isSending = true

        // Optimistic UI: add message immediately with .sending status
        let optimisticMessage = Message.textMessage(
            conversationId: conversationId,
            senderId: "local",
            text: text,
            isOutgoing: true
        )
        messages.append(optimisticMessage)

        do {
            let useCase = ChatUseCases.SendMessageUseCase(
                messageRepository: messageRepository,
                signalSessionManager: signalProtocol,
                chatDataSource: chatDataSource
            )
            let sentMessage = try await useCase.execute(
                text: text,
                conversationId: conversationId,
                recipientId: recipientId
            )
            // Replace optimistic message with server-confirmed message
            if let index = messages.firstIndex(where: { $0.id == optimisticMessage.id }) {
                messages[index] = sentMessage
            }
            SanchrLogger.chat.info("Message sent successfully")
        } catch {
            // Mark optimistic message as failed
            if let index = messages.firstIndex(where: { $0.id == optimisticMessage.id }) {
                messages[index].status = .failed
            }
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
        }
    }

    // MARK: - Load More (Pagination)

    /// Loads older messages for infinite scroll.
    func loadMore(conversationId: String, messageRepository: MessageRepositoryProtocol) async {
        guard !isLoadingMore, hasMoreMessages, let oldest = messages.first else { return }
        isLoadingMore = true

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
                messages.insert(contentsOf: olderMessages, at: 0)
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
        chatDataSource: ChatDataSource
    ) async {
        guard message.status == .failed, case .text(let text) = message.content else { return }

        // Remove the failed message
        messages.removeAll { $0.id == message.id }

        // Re-send
        inputText = text
        await sendMessage(
            conversationId: message.conversationId,
            recipientId: recipientId,
            messageRepository: messageRepository,
            signalProtocol: signalProtocol,
            chatDataSource: chatDataSource
        )
    }

    // MARK: - Delete Message

    func deleteMessage(
        _ message: Message,
        forEveryone: Bool,
        messageRepository: MessageRepositoryProtocol
    ) async {
        do {
            try await messageRepository.deleteMessage(id: message.id, forEveryone: forEveryone)
            messages.removeAll { $0.id == message.id }
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
}
