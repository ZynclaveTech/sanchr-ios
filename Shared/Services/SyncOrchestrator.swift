import Foundation

/// Protocol for background sync coordination.
protocol SyncOrchestratorProtocol: AnyObject, Sendable {
    func startSync() async
    func stopSync()
    var isSyncing: Bool { get }
}

/// Coordinates background sync of messages, contacts, and conversation state.
@Observable
final class SyncOrchestrator: SyncOrchestratorProtocol, @unchecked Sendable {
    private let messageRepository: MessageRepositoryProtocol
    private let contactRepository: ContactRepositoryProtocol
    private let networkMonitor: NetworkMonitorProtocol

    private var syncTask: Task<Void, Never>?
    private(set) var isSyncing: Bool = false

    init(
        messageRepository: MessageRepositoryProtocol,
        contactRepository: ContactRepositoryProtocol,
        networkMonitor: NetworkMonitorProtocol
    ) {
        self.messageRepository = messageRepository
        self.contactRepository = contactRepository
        self.networkMonitor = networkMonitor
    }

    func startSync() async {
        guard !isSyncing else { return }
        guard networkMonitor.isConnected else {
            SanchrLogger.sync.info("Skipping sync: no network connection")
            return
        }

        isSyncing = true
        SanchrLogger.sync.info("Starting background sync")

        syncTask = Task {
            do {
                // Sync conversations and messages
                _ = try await messageRepository.fetchConversations()
                SanchrLogger.sync.info("Conversations synced")

                // Sync contacts
                _ = try await contactRepository.fetchContacts()
                SanchrLogger.sync.info("Contacts synced")

                // Open message stream for real-time delivery
                let stream = try await messageRepository.openMessageStream()
                for await message in stream {
                    SanchrLogger.sync.debug("Received message: \(message.id)")
                    // TODO: Process incoming message, decrypt, store, notify
                }
            } catch {
                SanchrLogger.sync.error("Sync failed: \(error.localizedDescription)")
            }

            isSyncing = false
        }
    }

    func stopSync() {
        SanchrLogger.sync.info("Stopping background sync")
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
    }
}
