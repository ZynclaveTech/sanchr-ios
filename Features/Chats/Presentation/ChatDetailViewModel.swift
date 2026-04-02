import Foundation

/// View model for the chat conversation detail screen.
@Observable
final class ChatDetailViewModel {
    var messages: [Message] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var errorMessage: String?

    func loadMessages(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        isLoading = true
        defer { isLoading = false }

        do {
            messages = try await messageRepository.fetchMessages(
                conversationId: conversationId,
                before: nil,
                limit: 50
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendMessage(
        conversationId: String,
        recipientId: String,
        messageRepository: MessageRepositoryProtocol,
        signalProtocol: SignalProtocolManagerProtocol
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        let useCase = SendMessageUseCase(
            messageRepository: messageRepository,
            signalProtocol: signalProtocol
        )

        // Optimistic UI: add message immediately
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
        } catch {
            // Mark optimistic message as failed
            if let index = messages.firstIndex(where: { $0.id == optimisticMessage.id }) {
                messages[index].status = .failed
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Loads older messages for infinite scroll.
    func loadMore(conversationId: String, messageRepository: MessageRepositoryProtocol) async {
        guard let oldest = messages.first else { return }
        do {
            let olderMessages = try await messageRepository.fetchMessages(
                conversationId: conversationId,
                before: oldest.timestamp,
                limit: 30
            )
            messages.insert(contentsOf: olderMessages, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
