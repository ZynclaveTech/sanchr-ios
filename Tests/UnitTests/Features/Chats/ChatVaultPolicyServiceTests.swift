import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatVaultPolicyServiceTests: XCTestCase {

    func test_effectivePolicy_returnsDefaultsWhenCacheCold() {
        let service = ChatVaultPolicyService(localDatabase: StubVaultDatabase(), mirror: ChatVaultPolicyMirror())
        let policy = service.effectivePolicy(for: "c1")
        XCTAssertEqual(policy, .defaults(for: "c1"))
        XCTAssertNil(service.mirror.policy(for: "c1"))
    }

    func test_loadPolicy_hydratesCacheAndMirror() async {
        let db = StubVaultDatabase()
        db.policies["c1"] = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: true,
            screenshotProtection: false
        )
        let service = ChatVaultPolicyService(localDatabase: db, mirror: ChatVaultPolicyMirror())

        await service.loadPolicy(conversationId: "c1")

        XCTAssertEqual(service.effectivePolicy(for: "c1").autoVaultIncoming, true)
        XCTAssertEqual(service.mirror.policy(for: "c1")?.viewOnceOutgoing, true)
    }

    func test_loadPolicy_isIdempotent() async {
        let db = StubVaultDatabase()
        db.policies["c1"] = .defaults(for: "c1")
        let service = ChatVaultPolicyService(localDatabase: db, mirror: ChatVaultPolicyMirror())

        await service.loadPolicy(conversationId: "c1")
        // Mutate the DB out from under the service. Second load
        // should NOT pick up the change because we already cached.
        db.policies["c1"] = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: false
        )
        await service.loadPolicy(conversationId: "c1")

        XCTAssertFalse(service.effectivePolicy(for: "c1").autoVaultIncoming)
    }

    func test_setPolicy_persistsAndMirrorsAndBumpsVersion() async {
        let db = StubVaultDatabase()
        let service = ChatVaultPolicyService(localDatabase: db, mirror: ChatVaultPolicyMirror())
        let initialVersion = service.changeVersion

        let policy = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: true
        )
        await service.setPolicy(policy)

        XCTAssertEqual(db.policies["c1"], policy)
        XCTAssertEqual(service.effectivePolicy(for: "c1"), policy)
        XCTAssertEqual(service.mirror.policy(for: "c1"), policy)
        XCTAssertEqual(service.changeVersion, initialVersion &+ 1)
    }

    func test_setPolicy_postsNotification() async {
        let service = ChatVaultPolicyService(localDatabase: StubVaultDatabase(), mirror: ChatVaultPolicyMirror())
        let expectation = self.expectation(forNotification: .chatVaultPolicyDidChange, object: service)

        await service.setPolicy(.defaults(for: "c1"))

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}

/// Minimal LocalDatabase test double scoped to ChatVaultPolicyServiceTests.
/// Only the vault-policy methods are real; everything else
/// crash-on-call so accidental misuse during these tests is loud.
private final class StubVaultDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    var policies: [String: ChatVaultPolicy] = [:]

    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? {
        policies[conversationId]
    }
    func setVaultPolicy(_ policy: ChatVaultPolicy) async throws {
        policies[policy.conversationId] = policy
    }
    func clearVaultPolicy(conversationId: String) async throws {
        policies.removeValue(forKey: conversationId)
    }

    // Crash-on-call stubs for the rest of the protocol.
    func saveMessage(_ message: Message) async throws { fatalError() }
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws { fatalError() }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { fatalError() }
    func fetchMessageById(_ messageId: String) async throws -> Message? { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { fatalError() }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { fatalError() }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { fatalError() }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { fatalError() }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { fatalError() }
    func saveConversation(_ conversation: Conversation) async throws { fatalError() }
    func fetchConversation(id: String) async throws -> Conversation? { fatalError() }
    func fetchConversations() async throws -> [Conversation] { fatalError() }
    func deleteConversation(id: String) async throws { fatalError() }
    func saveContact(_ user: User) async throws { fatalError() }
    func fetchContacts() async throws -> [User] { fatalError() }
    func searchContacts(query: String) async throws -> [User] { fatalError() }
    func saveVaultItem(_ item: VaultItem) async throws { fatalError() }
    func fetchVaultItems() async throws -> [VaultItem] { fatalError() }
    func deleteVaultItem(id: String) async throws { fatalError() }
    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws { fatalError() }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { fatalError() }
    func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws { fatalError() }
    func deleteAccessKeyEntry(mediaId: String) async throws { fatalError() }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { fatalError() }
    func deleteAllAccessKeyEntries() async throws { fatalError() }
    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { fatalError() }
    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws { fatalError() }
    func clearAppearanceOverride(conversationId: String) async throws { fatalError() }
    func hasLocalHistory() async throws -> Bool { fatalError() }
    func exportBackupSnapshot(currentUserId: String?) async throws -> BackupArchiveSnapshot { fatalError() }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?) async throws { fatalError() }
    func purgeAllData() async throws { fatalError() }
}
