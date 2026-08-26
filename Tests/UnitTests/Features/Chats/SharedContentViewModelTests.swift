import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class SharedContentViewModelTests: XCTestCase {

    func test_loadInitial_partitionsMessagesIntoBuckets() async {
        let db = StubFetchDatabase()
        db.fetchMessagesResult = [
            Self.image(id: "i1", at: 100),
            Self.text(id: "t1", at: 200, body: "see https://example.com"),
            Self.document(id: "d1", at: 300, filename: "report.pdf"),
            Self.video(id: "v1", at: 400),
            Self.text(id: "t2", at: 500, body: "no link"),
            Self.text(id: "t3", at: 600, body: "https://news.example.org/story"),
        ]
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)

        XCTAssertEqual(vm.media.map(\.id), ["v1", "i1"])
        XCTAssertEqual(vm.docs.map(\.id), ["d1"])
        XCTAssertEqual(vm.links.map(\.id), ["t3", "t1"])
    }

    func test_loadInitial_emptyMessagesProducesEmptyBuckets() async {
        let db = StubFetchDatabase()
        db.fetchMessagesResult = []
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)

        XCTAssertTrue(vm.media.isEmpty)
        XCTAssertTrue(vm.docs.isEmpty)
        XCTAssertTrue(vm.links.isEmpty)
        XCTAssertFalse(vm.hasMore)
    }

    func test_loadMore_appendsToExistingBuckets() async {
        let db = StubFetchDatabase()
        db.fetchMessagesResult = [Self.image(id: "i1", at: 100)] + Self.fillerTexts(
            count: 99,
            startingAt: 1_000
        )
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)
        XCTAssertEqual(vm.media.map(\.id), ["i1"])

        // Next page returns one older media item.
        db.fetchMessagesResult = [Self.image(id: "i0", at: 50)]
        await vm.loadMore(conversationId: "conv", localDatabase: db)

        XCTAssertEqual(vm.media.map(\.id), ["i1", "i0"])
    }

    func test_linkExtractionPicksUpFirstURLOnly() async {
        let db = StubFetchDatabase()
        db.fetchMessagesResult = [
            Self.text(id: "t1", at: 100, body: "first https://a.example second https://b.example"),
        ]
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)

        XCTAssertEqual(vm.links.count, 1)
        XCTAssertEqual(vm.links.first?.url.absoluteString, "https://a.example")
    }

    // MARK: - Builders

    private static func image(id: String, at ts: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .image(Self.attachment("image/jpeg")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func video(id: String, at ts: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .video(Self.attachment("video/mp4")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func document(id: String, at ts: TimeInterval, filename: String) -> Message {
        var att = Self.attachment("application/pdf")
        att.filename = filename
        return Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .document(att),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func text(id: String, at ts: TimeInterval, body: String) -> Message {
        Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .text(body),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func attachment(_ mime: String) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://x")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mime,
            sizeBytes: 0
        )
    }

    private static func fillerTexts(count: Int, startingAt ts: TimeInterval) -> [Message] {
        (0..<count).map { index in
            text(
                id: "f\(index)",
                at: ts + Double(index),
                body: "no link \(index)"
            )
        }
    }
}

/// LocalDatabase test double for SharedContentViewModelTests. Only
/// `fetchMessages` returns real data; everything else crash-on-call.
private final class StubFetchDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    var fetchMessagesResult: [Message] = []

    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] {
        fetchMessagesResult
    }

    func saveMessage(_ message: Message) async throws { fatalError() }
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func purgeExpiredMessages() async throws -> [String] { [] }
    func deleteAllMessages(conversationId: String) async throws -> [String] { [] }
    func disappearingDuration(conversationId: String) async throws -> Int64 { 0 }
    func setDisappearingDuration(conversationId: String, seconds: Int64) async throws {}
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
    func fetchAllVaultItems() async throws -> [VaultItem] { fatalError() }
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
    func exportBackupSnapshot(currentUserId: String?, fingerprint: String) async throws -> BackupArchiveSnapshot { fatalError() }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?, localFingerprint: String) async throws { fatalError() }
    func purgeAllData() async throws { fatalError() }
}
