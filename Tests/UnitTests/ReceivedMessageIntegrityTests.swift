import SanchrShared
import XCTest

@testable import Sanchr

/// What a message from someone else may and may not do to what is already
/// on this phone.
///
/// Its id, and its claim to be this user's own message synced from another
/// device, are both fields of a payload the sender wrote.
final class ReceivedMessageIntegrityTests: XCTestCase {
    private var db: LocalDatabase!
    private let conversationId = "conv-1"

    override func setUp() async throws {
        try await super.setUp()
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("received-\(UUID().uuidString).sqlite")
        db = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        try await db.saveConversation(
            Conversation(
                id: conversationId,
                participants: [],
                unreadCount: 0,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                type: .oneToOne,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    private func message(
        from sender: String,
        _ text: String,
        outgoing: Bool = false,
        status: Message.DeliveryStatus = .delivered
    ) -> Message {
        Message(
            id: "m1",
            conversationId: conversationId,
            senderId: sender,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            content: .text(text),
            status: status,
            isOutgoing: outgoing
        )
    }

    private func storedText() async throws -> String? {
        guard case .text(let text)? = try await db.fetchMessageById("m1")?.content else { return nil }
        return text
    }

    // MARK: - A received message cannot replace one already held

    func testANewMessageIsSaved() async throws {
        let saved = try await db.saveReceivedMessage(message(from: "peer", "hello"), queueAck: true)

        XCTAssertTrue(saved)
        let text = try await storedText()
        XCTAssertEqual(text, "hello")
    }

    func testAMessageThisUserSentCannotBeRewrittenByThePersonItWentTo() async throws {
        try await db.saveMessage(message(from: "me", "I will pay you back Friday", outgoing: true, status: .sent))

        let saved = try await db.saveReceivedMessage(message(from: "peer", "I owe you nothing"), queueAck: true)

        XCTAssertFalse(saved)
        let stored = try await db.fetchMessageById("m1")
        XCTAssertEqual(stored?.senderId, "me")
        XCTAssertEqual(stored?.isOutgoing, true)
        let text = try await storedText()
        XCTAssertEqual(text, "I will pay you back Friday")
    }

    func testASenderCannotQuietlyChangeWhatTheySaidEarlier() async throws {
        _ = try await db.saveReceivedMessage(message(from: "peer", "what I really said"), queueAck: true)

        let saved = try await db.saveReceivedMessage(message(from: "peer", "what I wish I had said"), queueAck: true)

        XCTAssertFalse(saved)
        let text = try await storedText()
        XCTAssertEqual(text, "what I really said")
    }

    func testAnOpenedViewOnceIsNotRefilledWhenItIsSentAgain() async throws {
        _ = try await db.saveReceivedMessage(message(from: "peer", "the photo"), queueAck: true)
        var tombstone = message(from: "peer", "")
        tombstone.content = .system(.viewOnceConsumed)
        try await db.saveIncomingMessageAndQueueAck(tombstone)

        _ = try await db.saveReceivedMessage(message(from: "peer", "the photo"), queueAck: true)

        let stored = try await db.fetchMessageById("m1")
        guard case .system(.viewOnceConsumed)? = stored?.content else {
            return XCTFail("the opened view-once came back: \(String(describing: stored?.content))")
        }
    }

    func testARepeatDoesNotCountAsUnreadAgain() async throws {
        _ = try await db.saveReceivedMessage(message(from: "peer", "hello"), queueAck: true)
        _ = try await db.saveReceivedMessage(message(from: "peer", "hello"), queueAck: true)

        let conversation = try await db.fetchConversation(id: conversationId)
        XCTAssertEqual(conversation?.unreadCount, 1)
    }

    /// Left unacknowledged, the server would deliver it again for ever.
    func testARepeatIsStillAcknowledged() async throws {
        _ = try await db.saveReceivedMessage(message(from: "peer", "hello"), queueAck: true)
        let first = try await db.fetchPendingMessageAcks(limit: 10)
        try await db.deletePendingMessageAcks(first)

        _ = try await db.saveReceivedMessage(message(from: "peer", "hello"), queueAck: true)

        let acks = try await db.fetchPendingMessageAcks(limit: 10)
        XCTAssertEqual(acks.map(\.messageId), ["m1"])
    }

    // MARK: - Whose message it is

    func testOnlyThisUsersOwnDeviceCanSyncAMessageAsTheirs() {
        XCTAssertTrue(
            MessageRepositoryImpl.isOwnDeviceSync(
                payloadClaimsSync: true, authenticatedSenderId: "me", currentUserId: "me"))
    }

    /// The forgery: someone else sets the flag, and their words are filed as
    /// this user's.
    func testSomeoneElseClaimingToBeASyncIsJustSomeoneElse() {
        XCTAssertFalse(
            MessageRepositoryImpl.isOwnDeviceSync(
                payloadClaimsSync: true, authenticatedSenderId: "peer", currentUserId: "me"))
    }

    func testAnOrdinaryMessageIsNotASync() {
        XCTAssertFalse(
            MessageRepositoryImpl.isOwnDeviceSync(
                payloadClaimsSync: false, authenticatedSenderId: "peer", currentUserId: "me"))
        XCTAssertFalse(
            MessageRepositoryImpl.isOwnDeviceSync(
                payloadClaimsSync: false, authenticatedSenderId: "me", currentUserId: "me"))
    }

    func testWithNobodySignedInNothingIsTheirs() {
        XCTAssertFalse(
            MessageRepositoryImpl.isOwnDeviceSync(
                payloadClaimsSync: true, authenticatedSenderId: "", currentUserId: nil))
        XCTAssertFalse(
            MessageRepositoryImpl.isOwnDeviceSync(
                payloadClaimsSync: true, authenticatedSenderId: "", currentUserId: ""))
    }

    // MARK: - Wiring

    private func repositorySource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Shared/Repositories/MessageRepository.swift"),
            encoding: .utf8
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    }

    func testTheReceivePathTakesNeitherClaimOnTrust() throws {
        let source = try repositorySource()
        XCTAssertFalse(source.contains("let isOutgoing = innerPayload.isSync"))
        XCTAssertTrue(source.contains("authenticatedSenderId: result.senderUserId"))
        XCTAssertEqual(
            source.components(separatedBy: "localDatabase.saveReceivedMessage(message, queueAck:").count - 1,
            2,
            "both the sealed and the unsealed receive paths save without overwriting"
        )
    }
}
