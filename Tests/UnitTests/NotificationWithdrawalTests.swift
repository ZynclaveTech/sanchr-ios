import SanchrShared
import XCTest

@testable import Sanchr

/// A chat's delivered notifications come down when the chat is deleted,
/// hidden, cleared or read — not only when it is opened.
///
/// A notification can carry who wrote and a preview of what. Removed only on
/// opening the chat, it stayed on the lock screen after the chat it was
/// about had been deleted.
final class NotificationWithdrawalTests: XCTestCase {

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

    /// The body of the function starting at `signature`, up to the next
    /// function at the same indentation.
    private func body(of signature: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: signature), signature)
        let rest = source[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    /// "]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    func testDeletingHidingAndReadingAChatEachWithdrawItsNotifications() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        for signature in [
            "func deleteConversation(conversationId: String) async throws {",
            "func hideConversationLocally(conversationId: String) async throws {",
            "func markAsRead(conversationId: String, upToMessageId: String) async throws {",
            "func markAsReadLocally(conversationId: String, upToMessageId: String) async throws {",
        ] {
            XCTAssertTrue(
                try body(of: signature, in: repository).contains("clearNotifications(conversationId)"),
                signature
            )
        }
    }

    /// Restoring a hidden chat removes nothing: there is nothing stale to
    /// take down, and a notification that arrived meanwhile is still news.
    func testRestoringAChatLeavesItsNotificationsAlone() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        let restore = try body(
            of: "func restoreConversationLocally(conversationId: String) async throws {", in: repository)

        XCTAssertFalse(restore.contains("clearNotifications("))
    }

    func testClearingAChatWithdrawsItsNotifications() throws {
        let info = try source("Features/Chats/Presentation/ConversationInfoView.swift")
        let clear = try body(of: "private func clearAllMessages() async {", in: info)

        XCTAssertTrue(clear.contains("SanchrNotificationService.clearNotifications(for: conversation.id)"))
    }

    /// The real thing by default: a repository built without saying
    /// otherwise must not quietly do nothing.
    func testTheRepositoryClearsRealNotificationsUnlessToldOtherwise() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")

        XCTAssertTrue(repository.contains("SanchrNotificationService.clearNotifications(for: $0)"))
    }

    // MARK: - Expiry, Delete Message, blocking

    private final class Cleared: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    private func database() throws -> LocalDatabase {
        try LocalDatabase(
            path: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notif-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
    }

    private func user(_ id: String) -> User {
        User(
            id: id, phoneNumber: "", displayName: id, avatarURL: nil, bio: nil,
            isVerified: false, lastSeen: nil, identityKeyFingerprint: nil, status: .offline
        )
    }

    private func conversation(
        _ id: String,
        with participants: [String] = [],
        type: Conversation.ConversationType = .oneToOne
    ) -> Conversation {
        Conversation(
            id: id,
            participants: participants.map(user),
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: type,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func message(_ id: String, in conversationId: String, outgoing: Bool, expiresAt: Date?) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: outgoing ? "me" : "peer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            content: .text("hello"),
            status: .delivered,
            isOutgoing: outgoing,
            expiresAt: expiresAt
        )
    }

    /// Asked before the purge, because afterwards nothing says which chats
    /// the expired messages were in.
    func testOnlyChatsWithAnExpiredMessageFromSomeoneElseHaveANotificationToWithdraw() async throws {
        let db = try database()
        let past = Date(timeIntervalSinceNow: -60)
        let future = Date(timeIntervalSinceNow: 600)
        for id in ["theirs", "mine", "later", "plain"] {
            try await db.saveConversation(conversation(id))
        }
        try await db.saveMessage(message("a", in: "theirs", outgoing: false, expiresAt: past))
        try await db.saveMessage(message("b", in: "mine", outgoing: true, expiresAt: past))
        try await db.saveMessage(message("c", in: "later", outgoing: false, expiresAt: future))
        try await db.saveMessage(message("d", in: "plain", outgoing: false, expiresAt: nil))

        let ids = try await db.fetchConversationIdsWithExpiredIncomingMessages()

        XCTAssertEqual(ids, ["theirs"])
    }

    func testTheExpirySweepAsksBeforeItPurgesAndClearsAfter() throws {
        let sweeper = try source("Shared/Services/DisappearingMessageSweeper.swift")
        let ask = try XCTUnwrap(sweeper.range(of: "fetchConversationIdsWithExpiredIncomingMessages()"))
        let purge = try XCTUnwrap(sweeper.range(of: "localDatabase.purgeExpiredMessages()"))
        let clear = try XCTUnwrap(sweeper.range(of: "clearNotifications(conversationId)"))

        XCTAssertLessThan(ask.lowerBound, purge.lowerBound)
        XCTAssertLessThan(purge.lowerBound, clear.lowerBound)
    }

    func testDeletingAMessageSomeoneSentWithdrawsTheChatsNotifications() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        let delete = try body(of: "func deleteMessage(id: String, forEveryone: Bool) async throws {", in: repository)

        XCTAssertTrue(delete.contains("if let deleted, !deleted.isOutgoing {"))
        XCTAssertTrue(delete.contains("clearNotifications(deleted.conversationId)"))
        // Read before the row goes, or there is nothing to read.
        let read = try XCTUnwrap(delete.range(of: "localDatabase.fetchMessageById(id)"))
        let row = try XCTUnwrap(delete.range(of: "localDatabase.deleteMessage(id: id)"))
        XCTAssertLessThan(read.lowerBound, row.lowerBound)
    }

    func testBlockingSomeoneWithdrawsTheNotificationsOfTheChatWithThem() async throws {
        let db = try database()
        try await db.saveConversation(conversation("with-peer", with: ["me", "peer"]))
        try await db.saveConversation(conversation("with-other", with: ["me", "other"]))
        try await db.saveConversation(conversation("group", with: ["me", "peer", "other"], type: .group))
        let cleared = Cleared()
        let list = BlockList(localDatabase: db, cache: PrivacySettingsCache(), clearNotifications: { cleared.add($0) })

        await list.setBlocked("peer", true)

        XCTAssertEqual(cleared.all, ["with-peer"], "their own chat, not a group they are in, not anyone else's")
    }

    func testUnblockingWithdrawsNothing() async throws {
        let db = try database()
        try await db.saveConversation(conversation("with-peer", with: ["me", "peer"]))
        let cleared = Cleared()
        let list = BlockList(localDatabase: db, cache: PrivacySettingsCache(), clearNotifications: { cleared.add($0) })

        await list.setBlocked("peer", false)

        XCTAssertEqual(cleared.all, [])
    }
}
