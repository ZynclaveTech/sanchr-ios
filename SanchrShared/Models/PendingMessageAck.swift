import Foundation

public struct PendingMessageAck: Sendable, Equatable {
    public let conversationId: String
    public let messageId: String
    public let createdAt: Date

    public init(conversationId: String, messageId: String, createdAt: Date) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.createdAt = createdAt
    }
}
