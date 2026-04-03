import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Protocol for background sync coordination.
protocol SyncOrchestratorProtocol: AnyObject, Sendable {
    func startSync() async
    func stopSync()
    var isSyncing: Bool { get }

    func scheduleBackgroundSync()
    func scheduleAppRefresh()
    func registerHandlers()
}

/// Orchestrates background sync: pending messages, conversations, contacts,
/// vault expiry cleanup, pre-key replenishment, and badge count updates.
///
/// Uses `BGTaskScheduler` to register two task types:
/// - A `BGProcessingTask` for full sync (messages, conversations, keys, vault cleanup).
/// - A `BGAppRefreshTask` for lightweight message-only sync.
final class SyncOrchestrator: SyncOrchestratorProtocol, @unchecked Sendable {

    // MARK: - Task Identifiers

    /// Background processing task: full sync including conversations, keys, vault.
    static let syncTaskId = "com.sanchr.sync.messages"

    /// Background app refresh task: lightweight message-only sync.
    static let refreshTaskId = "com.sanchr.sync.refresh"

    // MARK: - Dependencies

    private let messageRepository: MessageRepositoryProtocol
    private let contactRepository: ContactRepositoryProtocol
    private let vaultRepository: VaultRepositoryProtocol
    private let signalKeyManager: KeyManagerProtocol
    private let sessionService: SessionService
    private let networkMonitor: NetworkMonitorProtocol
    private let localDatabase: LocalDatabaseProtocol
    let syncState: SyncState

    private var syncTask: Task<Void, Never>?

    var isSyncing: Bool {
        syncState.isSyncing
    }

    // MARK: - Init

    init(
        messageRepository: MessageRepositoryProtocol,
        contactRepository: ContactRepositoryProtocol,
        vaultRepository: VaultRepositoryProtocol,
        signalKeyManager: KeyManagerProtocol,
        sessionService: SessionService,
        networkMonitor: NetworkMonitorProtocol,
        localDatabase: LocalDatabaseProtocol,
        syncState: SyncState
    ) {
        self.messageRepository = messageRepository
        self.contactRepository = contactRepository
        self.vaultRepository = vaultRepository
        self.signalKeyManager = signalKeyManager
        self.sessionService = sessionService
        self.networkMonitor = networkMonitor
        self.localDatabase = localDatabase
        self.syncState = syncState
    }

    // MARK: - BGTaskScheduler Registration

    /// Register background task identifiers with the system.
    /// Must be called in `application(_:didFinishLaunchingWithOptions:)` before the app finishes launching.
    /// This performs the initial registration with placeholder handlers. Call `registerHandlers()`
    /// after the dependency container is ready to wire up the real sync logic.
    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: syncTaskId,
            using: nil
        ) { task in
            // Placeholder handler; replaced by `registerHandlers()` once the container is live.
            SanchrLogger.sync.warning(
                "BGProcessingTask fired before handler registration for \(syncTaskId)")
            task.setTaskCompleted(success: false)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskId,
            using: nil
        ) { task in
            SanchrLogger.sync.warning(
                "BGAppRefreshTask fired before handler registration for \(refreshTaskId)")
            task.setTaskCompleted(success: false)
        }

        SanchrLogger.sync.info(
            "Background task identifiers registered: \(syncTaskId), \(refreshTaskId)")
    }

    /// Re-register task handlers with a live orchestrator instance.
    /// Call this after the dependency container is fully initialized so the handler
    /// closures capture a real `SyncOrchestrator` reference.
    func registerHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.syncTaskId,
            using: nil
        ) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            nonisolated(unsafe) let orchestrator = self
            Task {
                await orchestrator.performSync(task: processingTask)
            }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskId,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            nonisolated(unsafe) let orchestrator = self
            Task {
                await orchestrator.performAppRefresh(task: refreshTask)
            }
        }

        SanchrLogger.sync.info("Background task handlers re-registered with live orchestrator")
    }

    // MARK: - Scheduling

    /// Schedule the next background processing sync.
    /// Call after each sync completes and when the app moves to the background.
    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: Self.syncTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Schedule no earlier than 15 minutes from now.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            SanchrLogger.sync.info("Scheduled background processing sync")
        } catch {
            SanchrLogger.sync.error(
                "Failed to schedule background sync: \(error.localizedDescription)")
        }
    }

    /// Schedule a background app refresh (lightweight sync).
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            SanchrLogger.sync.info("Scheduled background app refresh")
        } catch {
            SanchrLogger.sync.error("Failed to schedule app refresh: \(error.localizedDescription)")
        }
    }

    // MARK: - SyncOrchestratorProtocol (Foreground Sync)

    /// Foreground sync entry point. Performs a full sync while the app is active.
    func startSync() async {
        guard !syncState.isSyncing else {
            SanchrLogger.sync.info("Sync already in progress, skipping")
            return
        }
        guard networkMonitor.isConnected else {
            SanchrLogger.sync.info("Skipping sync: no network connection")
            return
        }
        guard sessionService.isAuthenticated else {
            SanchrLogger.sync.info("Skipping sync: user not authenticated")
            return
        }

        syncState.markSyncStarted()
        SanchrLogger.sync.info("Starting foreground sync")

        do {
            try await refreshTokenIfNeeded()
            let messageCount = try await syncPendingMessages()
            try await refreshConversations()
            try await replenishPreKeysIfNeeded()
            try await cleanExpiredVaultItems()
            await updateBadgeCount()

            syncState.markSyncCompleted(messageCount: messageCount)
            SanchrLogger.sync.info("Foreground sync completed: \(messageCount) new message(s)")
        } catch {
            syncState.markSyncFailed(error: error)
            SanchrLogger.sync.error("Foreground sync failed: \(error.localizedDescription)")
        }
    }

    /// Cancels any in-progress sync task.
    func stopSync() {
        SanchrLogger.sync.info("Stopping sync")
        syncTask?.cancel()
        syncTask = nil
        if syncState.isSyncing {
            syncState.markSyncFailed(error: CancellationError())
        }
    }

    // MARK: - BGTask Handlers

    /// Main sync handler for `BGProcessingTask`.
    /// Performs a full sync: token refresh, messages, conversations, keys, vault cleanup, badge.
    func performSync(task: BGProcessingTask) async {
        SanchrLogger.sync.info("BGProcessingTask: starting full sync")

        // Schedule the next occurrence before we begin work.
        scheduleBackgroundSync()

        nonisolated(unsafe) let orchestrator = self
        let workTask = Task {
            orchestrator.syncState.markSyncStarted()

            do {
                // Phase 1: Refresh auth token if expiring soon
                try await orchestrator.refreshTokenIfNeeded()

                // Phase 2: Sync pending messages
                let messageCount = try await orchestrator.syncPendingMessages()

                // Phase 3: Refresh conversations list
                try await orchestrator.refreshConversations()

                // Phase 4: Check and replenish pre-keys
                try await orchestrator.replenishPreKeysIfNeeded()

                // Phase 5: Clean expired vault items locally
                try await orchestrator.cleanExpiredVaultItems()

                // Phase 6: Update badge count
                await orchestrator.updateBadgeCount()

                orchestrator.syncState.markSyncCompleted(messageCount: messageCount)
                SanchrLogger.sync.info("BGProcessingTask completed: \(messageCount) new message(s)")
                task.setTaskCompleted(success: true)
            } catch {
                orchestrator.syncState.markSyncFailed(error: error)
                SanchrLogger.sync.error("BGProcessingTask failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        // If the system needs to terminate our task early, cancel the work.
        task.expirationHandler = {
            workTask.cancel()
            SanchrLogger.sync.warning("BGProcessingTask expired by system")
        }

        await workTask.value
    }

    /// App refresh handler for `BGAppRefreshTask`.
    /// Performs a lightweight sync: messages only and badge update.
    func performAppRefresh(task: BGAppRefreshTask) async {
        SanchrLogger.sync.info("BGAppRefreshTask: starting lightweight sync")

        // Schedule the next refresh before we begin.
        scheduleAppRefresh()

        nonisolated(unsafe) let orchestrator = self
        let workTask = Task {
            orchestrator.syncState.markSyncStarted()

            do {
                // Phase 1: Sync pending messages only
                let messageCount = try await orchestrator.syncPendingMessages()

                // Phase 2: Update badge count
                await orchestrator.updateBadgeCount()

                orchestrator.syncState.markSyncCompleted(messageCount: messageCount)
                SanchrLogger.sync.info("BGAppRefreshTask completed: \(messageCount) new message(s)")
                task.setTaskCompleted(success: true)
            } catch {
                orchestrator.syncState.markSyncFailed(error: error)
                SanchrLogger.sync.error("BGAppRefreshTask failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            workTask.cancel()
            SanchrLogger.sync.warning("BGAppRefreshTask expired by system")
        }

        await workTask.value
    }

    // MARK: - Individual Sync Operations

    /// Syncs pending messages from the server.
    /// - Returns: The number of new messages received.
    private func syncPendingMessages() async throws -> Int {
        SanchrLogger.sync.info("Syncing pending messages")

        // Fetch conversations to get any new messages via the repository layer.
        // The repository merges remote data with local storage.
        let conversations = try await messageRepository.fetchConversations()

        // Count total unread messages as a proxy for "new" messages.
        let newMessageCount = conversations.reduce(0) { $0 + $1.unreadCount }

        SanchrLogger.sync.info("Synced conversations, \(newMessageCount) unread message(s)")
        return newMessageCount
    }

    /// Refreshes the full conversations list and contacts from the server.
    private func refreshConversations() async throws {
        SanchrLogger.sync.info("Refreshing conversations list")
        _ = try await messageRepository.fetchConversations()

        // Also refresh the contacts list.
        _ = try await contactRepository.fetchContacts()

        SanchrLogger.sync.info("Conversations and contacts refreshed")
    }

    /// Checks the server pre-key count and replenishes if below threshold.
    private func replenishPreKeysIfNeeded() async throws {
        SanchrLogger.sync.info("Checking pre-key count")
        try await signalKeyManager.checkAndReplenishPreKeys(threshold: 25)
    }

    /// Removes expired vault items from the local database.
    private func cleanExpiredVaultItems() async throws {
        SanchrLogger.sync.info("Cleaning expired vault items")

        let items = try await vaultRepository.fetchItems()
        var removedCount = 0

        for item in items {
            // Remove items older than 30 days that are only cached locally
            // and no longer referenced on the server.
            if item.isCachedLocally,
                item.remoteURL == nil,
                item.updatedAt.timeIntervalSinceNow < -(30 * 24 * 60 * 60)
            {
                try await localDatabase.deleteVaultItem(id: item.id)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            SanchrLogger.sync.info("Removed \(removedCount) expired vault item(s)")
        }
    }

    /// Refreshes the auth token if it is expiring within 5 minutes.
    private func refreshTokenIfNeeded() async throws {
        SanchrLogger.sync.info("Checking auth token validity")
        try await sessionService.refreshTokenIfExpiringSoon()
    }

    /// Updates the app badge count on the home screen based on total unread messages.
    private func updateBadgeCount() async {
        let conversations = (try? await messageRepository.fetchConversations()) ?? []
        let totalUnread = conversations.reduce(0) { $0 + $1.unreadCount }

        await MainActor.run {
            UIApplication.shared.applicationIconBadgeNumber = totalUnread
        }

        SanchrLogger.sync.info("Badge count updated to \(totalUnread)")
    }
}
