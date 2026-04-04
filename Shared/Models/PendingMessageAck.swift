import Foundation

struct PendingMessageAck: Sendable, Equatable {
    let conversationId: String
    let messageId: String
    let createdAt: Date
}
