import Foundation
import SanchrShared

/// View model for the conversations list screen.
/// Manages loading, filtering, sorting, and mutation of the conversation list.
/// Observes `SyncState` to auto-refresh when a background sync completes.
@MainActor
@Observable
final class ChatsListViewModel {

    // MARK: - Filter

    enum ChatFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case groups = "Groups"

        var id: String { rawValue }
    }

    // MARK: - State

    var conversations: [Conversation] = [] {
        didSet { rebuildVisibleConversations() }
    }
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var errorMessage: String?
    var showEncryptionBanner: Bool = true
    var selectedFilter: ChatFilter = .all {
        didSet { rebuildVisibleConversations() }
    }
    var searchText: String = "" {
        didSet { rebuildVisibleConversations() }
    }

    /// Total unread count across all conversations for badge display.
    private(set) var totalUnreadCount: Int = 0

    /// Conversations that are pinned (for the pinned section).
    private(set) var pinnedConversations: [Conversation] = []

    /// Conversations that are not pinned (for the recent section).
    private(set) var recentConversations: [Conversation] = []

    /// Whether we've finished the first load attempt (either local cache or
    /// server). Used by the view to avoid flashing the "no conversations"
    /// empty state before cached data has had a chance to paint.
    private(set) var hasAttemptedInitialLoad: Bool = false

    /// Whether the list is empty (after loading).
    /// Returns `false` before the first load attempt completes so the view
    /// shows chrome + list skeleton instead of the empty state art while the
    /// local DB fetch is still in flight.
    var isEmpty: Bool {
        hasAttemptedInitialLoad
            && !isLoading
            && pinnedConversations.isEmpty
            && recentConversations.isEmpty
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

    // MARK: - Derived State

    private func rebuildVisibleConversations() {
        totalUnreadCount = conversations
            .filter { !$0.isArchived }
            .reduce(0) { $0 + $1.unreadCount }
        let visible = filteredConversations()
        pinnedConversations = visible.filter(\.isPinned)
        recentConversations = visible.filter { !$0.isPinned }
    }

    /// Returns conversations filtered by search text and active filter tab.
    private func filteredConversations() -> [Conversation] {
        var result = sortedConversations().filter { !$0.isArchived }

        // Apply filter tab
        switch selectedFilter {
        case .all:
            break
        case .unread:
            result = result.filter { $0.unreadCount > 0 }
        case .groups:
            result = result.filter { $0.type == .group }
        }

        // Apply search text
        if !searchText.isEmpty {
            let lowercased = searchText.lowercased()
            result = result.filter { $0.displayName.lowercased().contains(lowercased) }
        }

        return result
    }

    /// Conversations sorted by pinned status and last activity.
    private func sortedConversations() -> [Conversation] {
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

        defer {
            isLoading = false
            // Whether the fetch succeeded or failed, we've now attempted a
            // load — the view can safely render its empty-state art from
            // this point on. Never regresses back to false.
            hasAttemptedInitialLoad = true
        }

        do {
            conversations = try await messageRepository.fetchConversations()
            SanchrLogger.chat.info("Loaded \(self.conversations.count) conversations")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to load conversations: \(error.localizedDescription)")
        }
    }

    /// Fast local refresh used after realtime/local persistence updates so the list
    /// reflects new previews immediately without waiting on a server roundtrip.
    func loadCachedConversations(messageRepository: MessageRepositoryProtocol) async {
        do {
            // Normalizing local fetch: joins contacts so resolved names survive a
            // cache reload instead of reverting to the "Sanchr User" placeholder.
            conversations = try await messageRepository.fetchCachedConversations()
            errorMessage = nil
            SanchrLogger.chat.info("Loaded \(self.conversations.count) cached conversations")
        } catch {
            SanchrLogger.chat.warning("Cached conversation refresh failed: \(error.localizedDescription)")
        }
        // A cached-DB load counts as an initial-load attempt for UI purposes:
        // if the DB is genuinely empty the user can see the empty state
        // immediately without waiting for the server roundtrip.
        hasAttemptedInitialLoad = true
    }

    /// Refreshes a single conversation row from local persistence.
    func refreshConversation(id: String, localDatabase: LocalDatabaseProtocol) async {
        do {
            let refreshedConversation = try await localDatabase.fetchConversation(id: id)

            if let refreshedConversation {
                if let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index] = refreshedConversation
                } else {
                    conversations.append(refreshedConversation)
                }
            } else {
                conversations.removeAll { $0.id == id }
            }
            errorMessage = nil
        } catch {
            SanchrLogger.chat.warning(
                "Single conversation refresh failed for \(id.prefix(8)): \(error.localizedDescription)"
            )
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

    /// Deletes a conversation on the backend and locally.
    /// Falls back to local-only deletion when the backend RPC fails so the user
    /// is never blocked by a transient network issue.
    func deleteConversation(
        _ conversation: Conversation,
        messageRepository: MessageRepositoryProtocol,
        chatDataSource: ChatDataSource
    ) async {
        // Persist to backend (graceful degradation on failure)
        do {
            try await chatDataSource.deleteConversation(conversationId: conversation.id)
        } catch {
            SanchrLogger.chat.error("Backend conversation delete failed: \(error.localizedDescription)")
        }

        // Always hide locally regardless of RPC result
        do {
            try await messageRepository.hideConversationLocally(conversationId: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            SanchrLogger.chat.info("Deleted conversation \(conversation.id.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to hide conversation locally: \(error.localizedDescription)")
        }
    }

    /// Toggles the pin state of a conversation.
    func togglePin(_ conversation: Conversation, messageRepository: MessageRepositoryProtocol) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        let newValue = !conversations[index].isPinned
        do {
            try await messageRepository.setConversationPinned(
                conversationId: conversation.id,
                isPinned: newValue
            )
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to persist pin state: \(error.localizedDescription)")
            return
        }
        conversations[index].isPinned = newValue
        rebuildVisibleConversations()
        SanchrLogger.chat.info(
            "Toggled pin for \(conversation.id.prefix(8)): \(self.conversations[index].isPinned)")
    }

    /// Toggles the mute state of a conversation.
    func toggleMute(
        _ conversation: Conversation,
        messageRepository: MessageRepositoryProtocol,
        notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol
    ) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        let newValue = !conversations[index].isMuted
        do {
            var request = Sanchr_Notifications_SetConversationNotificationPrefsRequest()
            request.conversationID = conversation.id
            request.muted = newValue
            _ = try await notificationService.setConversationNotificationPrefs(request)

            try await messageRepository.setConversationMuted(
                conversationId: conversation.id,
                isMuted: newValue
            )
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to persist mute state: \(error.localizedDescription)")
            return
        }
        conversations[index].isMuted = newValue
        rebuildVisibleConversations()
    }

    /// Archives a conversation.
    func archiveConversation(
        _ conversation: Conversation,
        messageRepository: MessageRepositoryProtocol
    ) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        do {
            try await messageRepository.setConversationArchived(
                conversationId: conversation.id,
                isArchived: true
            )
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to persist archive state: \(error.localizedDescription)")
            return
        }
        conversations[index].isArchived = true
        conversations.removeAll { $0.id == conversation.id }
        SanchrLogger.chat.info("Archived conversation \(conversation.id.prefix(8))")
    }

    /// Marks a conversation as read: resets the in-memory unread count and sends a
    /// read receipt to the peer via the repository (which respects the privacy gate).
    func markAsRead(_ conversation: Conversation, messageRepository: MessageRepositoryProtocol) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        conversations[index].unreadCount = 0
        rebuildVisibleConversations()
        SanchrLogger.chat.info("Marked conversation \(conversation.id.prefix(8)) as read")

        guard let lastMessageId = conversation.lastMessage?.id else { return }
        try? await messageRepository.markAsRead(
            conversationId: conversation.id,
            upToMessageId: lastMessageId
        )
    }

    // MARK: - Dismiss Banner

    func dismissEncryptionBanner() {
        showEncryptionBanner = false
    }
}
