import Foundation
import SanchrShared

// MARK: - Reactions + Reply
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {

    // MARK: - Reactions

    func toggleReaction(
        emoji: String,
        messageId: String,
        conversationId: String,
        userId: String,
        chatDataSource: ChatDataSource
    ) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        let isRemoving = messages[index].reactions.contains(where: { $0.emoji == emoji && $0.userId == userId })

        if isRemoving, let reactionIndex = messages[index].reactions.firstIndex(where: { $0.emoji == emoji && $0.userId == userId }) {
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

        // Fire-and-forget gRPC call; revert local state on failure
        Task { [weak self] in
            do {
                try await chatDataSource.sendReaction(
                    messageID: messageId,
                    conversationID: conversationId,
                    userID: userId,
                    emoji: emoji,
                    removed: isRemoving
                )
            } catch {
                await MainActor.run {
                    guard let self,
                          let idx = self.messages.firstIndex(where: { $0.id == messageId }) else { return }

                    // Revert: if we added, remove it; if we removed, re-add it
                    if isRemoving {
                        let restored = Message.MessageReaction(
                            emoji: emoji,
                            userId: userId,
                            timestamp: Date()
                        )
                        self.messages[idx].reactions.append(restored)
                    } else {
                        self.messages[idx].reactions.removeAll(where: { $0.emoji == emoji && $0.userId == userId })
                    }
                    self.syncMessageSection(for: self.messages[idx])
                    SanchrLogger.chat.error("Failed to send reaction: \(error.localizedDescription)")
                }
            }
        }
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
}
