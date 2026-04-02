import Foundation

// TODO: Import SwiftData when targeting iOS 17+
// import SwiftData

/// Protocol for local database operations.
protocol LocalDatabaseProtocol: AnyObject, Sendable {
    // MARK: - Messages

    func saveMessage(_ message: Message) async throws
    func fetchMessages(conversationId: String, limit: Int, offset: Int) async throws -> [Message]
    func deleteMessage(id: String) async throws
    func markMessageAsRead(id: String) async throws

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) async throws
    func fetchConversations() async throws -> [Conversation]
    func deleteConversation(id: String) async throws

    // MARK: - Contacts

    func saveContact(_ user: User) async throws
    func fetchContacts() async throws -> [User]
    func searchContacts(query: String) async throws -> [User]

    // MARK: - Vault

    func saveVaultItem(_ item: VaultItem) async throws
    func fetchVaultItems() async throws -> [VaultItem]
    func deleteVaultItem(id: String) async throws

    // MARK: - Lifecycle

    func purgeAllData() async throws
}

/// SQLite/SwiftData backed local database manager.
/// All data is stored in an encrypted SQLite database.
final class LocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    // TODO: Replace with SwiftData ModelContainer
    // private let container: ModelContainer

    init() {
        SanchrLogger.persistence.info("LocalDatabase initialized")
        // TODO: Configure ModelContainer with encrypted store
        // let schema = Schema([MessageEntity.self, ConversationEntity.self, ...])
        // let config = ModelConfiguration(isStoredInMemoryOnly: false)
        // container = try! ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Messages

    func saveMessage(_ message: Message) async throws {
        // TODO: Implement SwiftData insert
        SanchrLogger.persistence.debug("Saving message \(message.id)")
    }

    func fetchMessages(conversationId: String, limit: Int, offset: Int) async throws -> [Message] {
        // TODO: Implement SwiftData fetch with predicate and pagination
        return []
    }

    func deleteMessage(id: String) async throws {
        // TODO: Implement SwiftData delete
    }

    func markMessageAsRead(id: String) async throws {
        // TODO: Implement status update
    }

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) async throws {
        // TODO: Implement
    }

    func fetchConversations() async throws -> [Conversation] {
        return []
    }

    func deleteConversation(id: String) async throws {
        // TODO: Implement
    }

    // MARK: - Contacts

    func saveContact(_ user: User) async throws {
        // TODO: Implement
    }

    func fetchContacts() async throws -> [User] {
        return []
    }

    func searchContacts(query: String) async throws -> [User] {
        // TODO: Implement FTS search
        return []
    }

    // MARK: - Vault

    func saveVaultItem(_ item: VaultItem) async throws {
        // TODO: Implement
    }

    func fetchVaultItems() async throws -> [VaultItem] {
        return []
    }

    func deleteVaultItem(id: String) async throws {
        // TODO: Implement
    }

    // MARK: - Lifecycle

    func purgeAllData() async throws {
        SanchrLogger.persistence.warning("Purging all local data")
        // TODO: Delete all entities and reset database
    }
}
