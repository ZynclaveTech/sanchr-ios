import Foundation

/// View model for the conversations list screen.
/// Manages loading, filtering, sorting, and mutation of the conversation list.
/// Observes `SyncState` to auto-refresh when a background sync completes.
@Observable
final class ChatsListViewModel {

    // MARK: - State

    var conversations: [Conversation] = []
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var errorMessage: String?
    var showEncryptionBanner: Bool = true

    /// Total unread count across all conversations for badge display.
    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    /// Whether the list is empty (after loading).
    var isEmpty: Bool {
        !isLoading && conversations.isEmpty
    }

    // MARK: - Sync State Observation

    /// Reference to the shared sync state for observing sync lifecycle.
    private var syncState: SyncState?

    /// Tracks the last sync timestamp we reacted to, so we only refresh once per sync.
    private var lastObservedSyncTimestamp: Date?

    /// Whether the sync orchestrator is currently syncing (drives "Syncing..." indicator).
    var isSyncing: Bool {
        syncState?.isSyncing ?? false
    }

    /// Configures the view model to observe the given `SyncState`.
    /// Call this from the view's `.onAppear` or `.task` modifier.
    func observeSyncState(_ syncState: SyncState) {
        self.syncState = syncState
    }

    /// Checks whether a background sync has completed since our last observation
    /// and refreshes the conversation list if so.
    /// Call this from a periodic timer or `.onChange(of: syncState.lastSyncTimestamp)`.
    func refreshIfSyncCompleted(messageRepository: MessageRepositoryProtocol) async {
        guard let syncState else { return }
        guard let latestSync = syncState.lastSyncTimestamp else { return }

        // Only refresh if the sync timestamp has advanced.
        if let lastObserved = lastObservedSyncTimestamp, latestSync <= lastObserved {
            return
        }

        lastObservedSyncTimestamp = latestSync
        SanchrLogger.chat.info("Background sync completed, refreshing conversations")

        do {
            conversations = try await messageRepository.fetchConversations()
            errorMessage = nil
        } catch {
            SanchrLogger.chat.error("Post-sync refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Filtering & Sorting

    /// Returns conversations filtered by search text.
    func filteredConversations(searchText: String) -> [Conversation] {
        guard !searchText.isEmpty else {
            return sortedConversations
        }
        let lowercased = searchText.lowercased()
        return sortedConversations.filter { conversation in
            conversation.displayName.lowercased().contains(lowercased)
        }
    }

    /// Conversations sorted by pinned status and last activity.
    private var sortedConversations: [Conversation] {
        conversations.sorted { lhs, rhs in
            // Pinned conversations always sort first
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            // Then by most recent activity
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    // MARK: - Load Conversations

    /// Initial load of conversations on screen appear.
    func loadConversations(messageRepository: MessageRepositoryProtocol) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            conversations = try await messageRepository.fetchConversations()
            SanchrLogger.chat.info("Loaded \(self.conversations.count) conversations")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to load conversations: \(error.localizedDescription)")
        }
    }

    // MARK: - Pull to Refresh

    /// Refreshes the conversation list via pull-to-refresh.
    /// When a `SyncOrchestrator` is available, triggers a full foreground sync;
    /// otherwise falls back to a direct repository fetch.
    func refresh(
        messageRepository: MessageRepositoryProtocol,
        syncOrchestrator: SyncOrchestratorProtocol? = nil
    ) async {
        isRefreshing = true
        defer { isRefreshing = false }

        // If we have a sync orchestrator, use it for a full sync (messages + keys + vault).
        if let orchestrator = syncOrchestrator {
            await orchestrator.startSync()
            // After sync completes, fetch the latest conversations.
            do {
                conversations = try await messageRepository.fetchConversations()
                errorMessage = nil
                SanchrLogger.chat.info(
                    "Pull-to-refresh via sync: \(self.conversations.count) conversations")
            } catch {
                errorMessage = error.localizedDescription
                SanchrLogger.chat.error("Post-sync fetch failed: \(error.localizedDescription)")
            }
            return
        }

        // Fallback: direct repository refresh.
        do {
            conversations = try await messageRepository.fetchConversations()
            errorMessage = nil
            SanchrLogger.chat.info("Refreshed \(self.conversations.count) conversations")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Conversation Actions

    /// Deletes a conversation locally (and eventually on server).
    func deleteConversation(_ conversation: Conversation) async {
        SanchrLogger.chat.info("Deleting conversation \(conversation.id.prefix(8))...")
        conversations.removeAll { $0.id == conversation.id }
        // TODO: Delete via repository/server
    }

    /// Toggles the pin state of a conversation.
    func togglePin(_ conversation: Conversation) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        conversations[index].isPinned.toggle()
        SanchrLogger.chat.info(
            "Toggled pin for \(conversation.id.prefix(8)): \(self.conversations[index].isPinned)")
        // TODO: Persist pin state
    }

    /// Toggles the mute state of a conversation.
    func toggleMute(_ conversation: Conversation) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        conversations[index].isMuted.toggle()
        // TODO: Persist mute state
    }

    /// Archives a conversation.
    func archiveConversation(_ conversation: Conversation) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        conversations[index].isArchived = true
        // TODO: Persist archive state
    }

    // MARK: - Dismiss Banner

    func dismissEncryptionBanner() {
        showEncryptionBanner = false
    }
}
