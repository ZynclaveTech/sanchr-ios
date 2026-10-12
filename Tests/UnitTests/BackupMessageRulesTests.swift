import SanchrShared
import XCTest

@testable import Sanchr

/// A backup keeps things. Some messages were sent on the understanding that
/// nothing would.
final class BackupMessageRulesTests: XCTestCase {

    private func database() throws -> LocalDatabase {
        try LocalDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
    }

    private func conversation(_ id: String = "c1") -> Conversation {
        Conversation(
            id: id, participants: [], unreadCount: 0, isPinned: false, isMuted: false, isArchived: false,
            type: .oneToOne, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func photo(viewOnce: Bool?) -> Message.MessageContent {
        .image(
            Message.MediaAttachments(
                Message.MediaAttachment(
                    url: URL(string: "sanchr-media://m")!, encryptionKey: Data([1]), encryptionIV: Data([2]),
                    mimeType: "image/jpeg", sizeBytes: 10, isViewOnce: viewOnce)))
    }

    private func message(
        _ id: String,
        _ content: Message.MessageContent = .text("hello"),
        at seconds: TimeInterval,
        expiresAt: Date? = nil
    ) -> Message {
        Message(
            id: id, conversationId: "c1", senderId: "peer", timestamp: Date(timeIntervalSince1970: seconds),
            content: content, status: .delivered, isOutgoing: false, expiresAt: expiresAt
        )
    }

    // MARK: - The rule

    func testAnOrdinaryMessageAndAnOrdinaryPhotoAreBackedUp() {
        XCTAssertTrue(BackupMessageRules.belongsInBackup(content: .text("hi"), expiresAt: nil))
        XCTAssertTrue(BackupMessageRules.belongsInBackup(content: photo(viewOnce: nil), expiresAt: nil))
        XCTAssertTrue(BackupMessageRules.belongsInBackup(content: photo(viewOnce: false), expiresAt: nil))
    }

    /// Backed up, it outlives its timer by as long as the backup does.
    func testADisappearingMessageIsNotWhetherOrNotItsTimeIsUp() {
        XCTAssertFalse(BackupMessageRules.belongsInBackup(content: .text("hi"), expiresAt: .distantPast))
        XCTAssertFalse(BackupMessageRules.belongsInBackup(content: .text("hi"), expiresAt: .distantFuture))
    }

    /// The backup would hold the keys to see it again.
    func testViewOnceMediaIsNot() {
        XCTAssertFalse(BackupMessageRules.belongsInBackup(content: photo(viewOnce: true), expiresAt: nil))
    }

    func testTheMarkerLeftWhereAViewOnceWasOpenedIsBackedUp() {
        XCTAssertTrue(BackupMessageRules.belongsInBackup(content: .system(.viewOnceConsumed), expiresAt: nil))
    }

    func testContentThatCannotBeReadIsNotTreatedAsViewOnce() {
        XCTAssertTrue(BackupMessageRules.belongsInBackup(content: nil, expiresAt: nil))
    }

    // MARK: - Making a backup

    func testABackupLeavesOutDisappearingMessagesAndViewOnceMedia() async throws {
        let db = try database()
        try await db.saveConversation(conversation())
        try await db.saveMessage(message("plain", at: 10))
        try await db.saveMessage(message("photo", photo(viewOnce: nil), at: 20))
        try await db.saveMessage(message("timed", at: 30, expiresAt: .distantFuture))
        try await db.saveMessage(message("once", photo(viewOnce: true), at: 40))

        let snapshot = try await db.exportBackupSnapshot(currentUserId: "me", fingerprint: "f")

        XCTAssertEqual(Set(snapshot.messages.map(\.id)), ["plain", "photo"])
        XCTAssertTrue(snapshot.messages.allSatisfy { $0.expiresAtMs == nil })
    }

    /// A chat's preview is a copy of its last message's text.
    func testAChatsPreviewIsLeftOutWhenItsMessageIs() async throws {
        let db = try database()
        try await db.saveConversation(conversation())
        try await db.saveMessage(message("plain", .text("fine to keep"), at: 10))
        try await db.saveMessage(message("timed", .text("gone in an hour"), at: 30, expiresAt: .distantFuture))

        let snapshot = try await db.exportBackupSnapshot(currentUserId: "me", fingerprint: "f")

        let chat = try XCTUnwrap(snapshot.conversations.first)
        XCTAssertNil(chat.lastMessageID)
        XCTAssertNil(chat.lastMessagePreview)
        XCTAssertNil(chat.lastMessageContentBody)
        XCTAssertNil(chat.lastMessageSenderID)
        let everything = String(describing: snapshot)
        XCTAssertFalse(everything.contains("gone in an hour"))
    }

    func testAChatsPreviewIsKeptWhenItsMessageIs() async throws {
        let db = try database()
        try await db.saveConversation(conversation())
        try await db.saveMessage(message("plain", .text("fine to keep"), at: 10))

        let snapshot = try await db.exportBackupSnapshot(currentUserId: "me", fingerprint: "f")

        let chat = try XCTUnwrap(snapshot.conversations.first)
        XCTAssertEqual(chat.lastMessageID, "plain")
        XCTAssertEqual(chat.lastMessagePreview, "fine to keep")
    }

    // MARK: - Restoring one

    private func frame(_ id: String, expiresAtMs: Int64? = nil, isDeleted: Bool = false) -> BackupArchiveMessageFrame {
        BackupArchiveMessageFrame(
            id: id, conversationID: "c1", senderID: "peer", timestampMs: 10_000, contentType: "text",
            contentBody: "hello", previewText: "hello", status: "delivered", isOutgoing: false,
            replyToMessageID: nil, expiresAtMs: expiresAtMs, isDeleted: isDeleted
        )
    }

    /// An older backup, or one from an app without this rule, may hold them.
    func testARestoreTakesNeitherDisappearingMessagesNorDeletedPlaceholders() async throws {
        let source = try database()
        try await source.saveConversation(conversation())
        var snapshot = try await source.exportBackupSnapshot(currentUserId: "me", fingerprint: "f")
        snapshot.messages = [
            frame("plain"),
            frame("timed", expiresAtMs: 4_000_000_000_000),
            frame("deleted", isDeleted: true),
        ]

        let target = try database()
        try await target.restoreBackupSnapshot(snapshot, currentUserId: "me", localFingerprint: "f")

        let restored = try await target.fetchMessageIds(conversationId: "c1")
        XCTAssertEqual(restored, ["plain"])
    }

    func testTheRuleForARestore() {
        XCTAssertTrue(BackupMessageRules.mayRestore(frame("a")))
        XCTAssertFalse(BackupMessageRules.mayRestore(frame("a", expiresAtMs: 1)))
        XCTAssertFalse(BackupMessageRules.mayRestore(frame("a", isDeleted: true)))
    }
}
