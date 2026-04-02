import Foundation

/// View model for the chat conversation detail screen.
/// Manages messages, input, sending, optimistic updates, and pagination.
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
                  let rhsDate = rhs.value.first?.timestamp else { return false }
            return lhsDate < rhsDate
        }
    }

    /// Whether there are more messages to load.
    var hasMoreMessages: Bool = true

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
            SanchrLogger.chat.info("Loaded \(self.messages.count) messages for \(conversationId.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to load messages: \(error.localizedDescription)")
        }
    }

    // MARK: - Send Message

    func sendMessage(
        conversationId: String,
        recipientId: String,
        messageRepository: MessageRepositoryProtocol,
        signalProtocol: SignalProtocolManagerProtocol
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input immediately for responsive UI
        inputText = ""
        isSending = true

        let useCase = SendMessageUseCase(
            messageRepository: messageRepository,
            signalProtocol: signalProtocol
        )

        // Optimistic UI: add message immediately with .sending status
        let optimisticMessage = Message.textMessage(
            conversationId: conversationId,
            senderId: "local",
            text: text,
            isOutgoing: true
        )
        messages.append(optimisticMessage)

        do {
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
        signalProtocol: SignalProtocolManagerProtocol
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
            signalProtocol: signalProtocol
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
