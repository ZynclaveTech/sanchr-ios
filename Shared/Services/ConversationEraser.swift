import Foundation
import SanchrShared

/// Removes a conversation from this phone: its messages, what those messages
/// had put on disk, and the conversation itself.
///
/// "Delete Conversation" used to do none of that. It set the flag that hides
/// a chat, so every message and every decrypted photo stayed, and the chat
/// could be brought back whole from Hidden Chats — after the server had been
/// told it was deleted.
///
/// The files go before the rows and again after them. Before, because the
/// rows are what say which files these are, and that pass is the only one
/// that runs if the app dies part way. After, because a chat that is open
/// can fetch a picture again in between, and nothing asks once its row is
/// gone.
struct ConversationEraser: Sendable {
    let localDatabase: LocalDatabaseProtocol
    let removeCachedFile: @Sendable (_ messageId: String) async -> Void

    /// - Returns: how many messages went with it.
    @discardableResult
    func erase(conversationId: String) async throws -> Int {
        let held = try await localDatabase.fetchMessageIds(conversationId: conversationId)
        for id in held {
            await removeCachedFile(id)
        }
        let deleted = try await localDatabase.deleteAllMessages(conversationId: conversationId)
        try await localDatabase.deleteConversation(id: conversationId)
        for id in Set(held).union(deleted) {
            await removeCachedFile(id)
        }
        return deleted.count
    }
}
