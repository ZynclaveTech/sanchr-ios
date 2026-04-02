import Foundation

/// View model for the conversations list screen.
@Observable
final class ChatsListViewModel {
    var conversations: [Conversation] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var showEncryptionBanner: Bool = true

    /// Returns conversations filtered by search text.
    func filteredConversations(searchText: String) -> [Conversation] {
        guard !searchText.isEmpty else {
            return sortedConversations
        }
        return sortedConversations.filter { conversation in
            conversation.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Conversations sorted by pinned status and last activity.
    private var sortedConversations: [Conversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    func loadConversations(messageRepository: MessageRepositoryProtocol) async {
        isLoading = true
        defer { isLoading = false }

        do {
            conversations = try await messageRepository.fetchConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh(messageRepository: MessageRepositoryProtocol) async {
        do {
            conversations = try await messageRepository.fetchConversations()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteConversation(_ conversation: Conversation) async {
        // TODO: Delete conversation via repository
        conversations.removeAll { $0.id == conversation.id }
    }

    func togglePin(_ conversation: Conversation) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].isPinned.toggle()
        // TODO: Persist pin state
    }
}
