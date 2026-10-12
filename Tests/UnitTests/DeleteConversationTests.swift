import SanchrShared
import XCTest

@testable import Sanchr

/// Deleting a conversation deletes it. Hiding it is a different thing.
///
/// "Delete Conversation" used to set the flag that hides a chat: every
/// message and photo stayed on the phone, and the chat could be restored
/// whole from Hidden Chats.
@MainActor
final class DeleteConversationTests: XCTestCase {
    private var db: LocalDatabase!
    private var removed: RemovedFiles!

    private final class RemovedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    override func setUp() async throws {
        try await super.setUp()
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("delete-conv-\(UUID().uuidString).sqlite")
        db = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        removed = RemovedFiles()
    }

    private func conversation(_ id: String) -> Conversation {
        Conversation(
            id: id,
            participants: [],
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func seed(_ conversationId: String, messages ids: [String], expiresAt: Date? = nil) async throws {
        try await db.saveConversation(conversation(conversationId))
        for id in ids {
            try await db.saveMessage(
                Message(
                    id: id,
                    conversationId: conversationId,
                    senderId: "peer",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                    content: .text("hello"),
                    status: .delivered,
                    isOutgoing: false,
                    expiresAt: expiresAt
                )
            )
        }
    }

    private func eraser() -> ConversationEraser {
        let removed = removed!
        return ConversationEraser(localDatabase: db, removeCachedFile: { removed.add($0) })
    }

    // MARK: - Erasing

    func testTheConversationItsMessagesAndTheirMediaAllGo() async throws {
        try await seed("c1", messages: ["m1", "m2"])

        let count = try await eraser().erase(conversationId: "c1")

        XCTAssertEqual(count, 2)
        let conversation = try await db.fetchConversation(id: "c1")
        XCTAssertNil(conversation)
        let left = try await db.fetchMessageIds(conversationId: "c1")
        XCTAssertEqual(left, [])
        XCTAssertEqual(Set(removed.all), ["m1", "m2"])
    }

    /// Not in Hidden Chats either: that is where it used to end up.
    func testADeletedConversationIsNotAHiddenOne() async throws {
        try await seed("c1", messages: ["m1"])

        try await eraser().erase(conversationId: "c1")

        let hidden = try await db.fetchHiddenChatSummaries()
        XCTAssertEqual(hidden.map(\.id), [])
        let everything = try await db.fetchAllConversationsIncludingHidden()
        XCTAssertEqual(everything.map(\.id), [])
    }

    func testAnotherConversationIsLeftAlone() async throws {
        try await seed("c1", messages: ["m1"])
        try await seed("c2", messages: ["m2"])

        try await eraser().erase(conversationId: "c1")

        let kept = try await db.fetchMessageIds(conversationId: "c2")
        XCTAssertEqual(kept, ["m2"])
        XCTAssertFalse(removed.all.contains("m2"))
    }

    /// Each file is removed before its row goes and again after: see
    /// `ConversationEraser`.
    func testEachFileIsRemovedTwice() async throws {
        try await seed("c1", messages: ["m1"])

        try await eraser().erase(conversationId: "c1")

        XCTAssertEqual(removed.all, ["m1", "m1"])
    }

    /// Reading a chat leaves out messages past their deadline. Deleting it
    /// must not.
    func testAMessagePastItsDisappearingDeadlineGoesToo() async throws {
        try await seed("c1", messages: ["expired"], expiresAt: Date(timeIntervalSinceNow: -60))

        try await eraser().erase(conversationId: "c1")

        XCTAssertTrue(removed.all.contains("expired"))
    }

    func testHidingKeepsEverything() async throws {
        try await seed("c1", messages: ["m1"])

        try await db.setConversationHidden(id: "c1", isHidden: true)

        let kept = try await db.fetchMessageIds(conversationId: "c1")
        XCTAssertEqual(kept, ["m1"])
        let hidden = try await db.fetchHiddenChatSummaries()
        XCTAssertEqual(hidden.map(\.id), ["c1"])
    }

    // MARK: - A delete the server has not taken yet

    func testARefreshDoesNotBringBackAConversationWhoseDeleteIsStillQueued() {
        let kept = MessageRepositoryImpl.withoutPendingDeletes(
            ["c1", "c2", "c3"], id: { $0 }, pending: ["c2"])

        XCTAssertEqual(kept, ["c1", "c3"])
    }

    func testWithNothingQueuedARefreshWritesEverything() {
        let kept = MessageRepositoryImpl.withoutPendingDeletes(["c1", "c2"], id: { $0 }, pending: [])

        XCTAssertEqual(kept, ["c1", "c2"])
    }

    // MARK: - The chat list

    func testDeleteOnTheChatListDeletesAndHideHides() async {
        let repository = MockMessageRepository()
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("c1"), conversation("c2"), conversation("c3")]

        await vm.deleteConversation(conversation("c1"), messageRepository: repository)
        await vm.hideConversation(conversation("c2"), messageRepository: repository)

        XCTAssertEqual(repository.deletedConversationIds, ["c1"])
        XCTAssertEqual(repository.hiddenConversationIds, ["c2"])
        XCTAssertEqual(vm.conversations.map(\.id), ["c3"])
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// The repository's delete has to go through the eraser, and must not go
    /// back to hiding.
    func testTheRepositoryDeletesRatherThanHides() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        let start = try XCTUnwrap(repository.range(of: "func deleteConversation(conversationId: String) async throws {"))
        let rest = repository[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]

        XCTAssertTrue(body.contains("ConversationEraser("))
        XCTAssertTrue(body.contains("enqueuePendingConversationDelete"))
        XCTAssertFalse(body.contains("setConversationHidden"))
    }
}
