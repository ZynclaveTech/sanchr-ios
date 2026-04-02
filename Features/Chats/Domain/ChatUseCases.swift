import Foundation

/// Domain use cases for chat operations.
enum ChatUseCases {

    /// Fetches the conversation list with unread counts.
    struct FetchConversations: Sendable {
        private let messageRepository: MessageRepositoryProtocol

        init(messageRepository: MessageRepositoryProtocol) {
            self.messageRepository = messageRepository
        }

        func execute() async throws -> [Conversation] {
            try await messageRepository.fetchConversations()
        }
    }

    /// Marks all messages in a conversation as read.
    struct MarkAsRead: Sendable {
        private let messageRepository: MessageRepositoryProtocol

        init(messageRepository: MessageRepositoryProtocol) {
            self.messageRepository = messageRepository
        }

        func execute(conversationId: String, upToMessageId: String) async throws {
            try await messageRepository.markAsRead(
                conversationId: conversationId,
                upToMessageId: upToMessageId
            )
        }
    }

    /// Deletes a message locally or for everyone.
    struct DeleteMessage: Sendable {
        private let messageRepository: MessageRepositoryProtocol

        init(messageRepository: MessageRepositoryProtocol) {
            self.messageRepository = messageRepository
        }

        func execute(messageId: String, forEveryone: Bool) async throws {
            try await messageRepository.deleteMessage(id: messageId, forEveryone: forEveryone)
        }
    }
}
