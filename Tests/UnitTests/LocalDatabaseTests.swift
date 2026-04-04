import Foundation
import GRDB
import XCTest

@testable import Sanchr

final class LocalDatabaseTests: XCTestCase {
    func testFetchMessagesHonorsBeforeCursorAndReturnsAscendingOrder() async throws {
        let path = makeTemporaryDatabasePath()
        let database = LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        let conversation = makeConversation(id: "conversation-1")

        try await database.saveConversation(conversation)

        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let message1 = makeMessage(id: "message-1", conversationId: conversation.id, timestamp: baseDate)
        let message2 = makeMessage(
            id: "message-2",
            conversationId: conversation.id,
            timestamp: baseDate.addingTimeInterval(60)
        )
        let message3 = makeMessage(
            id: "message-3",
            conversationId: conversation.id,
            timestamp: baseDate.addingTimeInterval(120)
        )

        try await database.saveMessage(message1)
        try await database.saveMessage(message2)
        try await database.saveMessage(message3)

        let fetched = try await database.fetchMessages(
            conversationId: conversation.id,
            before: message3.timestamp,
            limit: 10
        )

        XCTAssertEqual(fetched.map(\.id), ["message-1", "message-2"])
    }

    func testEncryptedDatabaseCannotBeOpenedWithoutPassphrase() async throws {
        let path = makeTemporaryDatabasePath()
        let database = LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })

        try await database.saveConversation(makeConversation(id: "conversation-2"))

        do {
            let plainDatabase = try DatabaseQueue(path: path)
            _ = try await plainDatabase.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
            }
            XCTFail("Expected encrypted database to reject plaintext reads")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testPlaintextDatabaseMigratesToEncryptedDatabase() async throws {
        let path = makeTemporaryDatabasePath()
        let conversation = makeConversation(id: "conversation-3")
        let message = makeMessage(
            id: "message-migrated",
            conversationId: conversation.id,
            timestamp: Date(timeIntervalSince1970: 1_750_000_500)
        )

        let plaintextDatabase = try DatabaseQueue(path: path)
        try DatabaseSchema.migrator.migrate(plaintextDatabase)
        try await plaintextDatabase.write { db in
            try ConversationRecord(from: conversation).insert(db)

            for participant in conversation.participants {
                try UserRecord(from: participant).insert(db)
                try ConversationParticipantRecord(
                    conversationId: conversation.id,
                    userId: participant.id
                ).insert(db)
            }

            try MessageRecord(from: message).insert(db)
        }

        let encryptedDatabase = LocalDatabase(path: path, passphraseProvider: { "migrated-passphrase" })
        let fetched = try await encryptedDatabase.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 10
        )

        XCTAssertEqual(fetched.map(\.id), ["message-migrated"])

        do {
            let plainDatabaseAfterMigration = try DatabaseQueue(path: path)
            _ = try await plainDatabaseAfterMigration.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
            }
            XCTFail("Expected migrated encrypted database to reject plaintext reads")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    private func makeTemporaryDatabasePath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sanchr-tests.sqlite").path
    }

    private func makeConversation(id: String) -> Conversation {
        Conversation(
            id: id,
            participants: [
                User(
                    id: "local-user",
                    phoneNumber: "+15550000001",
                    displayName: "Local User",
                    avatarURL: nil,
                    bio: nil,
                    isVerified: true,
                    lastSeen: nil,
                    identityKeyFingerprint: nil,
                    status: .online,
                    isLocalUser: true
                ),
                User(
                    id: "remote-user",
                    phoneNumber: "+15550000002",
                    displayName: "Remote User",
                    avatarURL: nil,
                    bio: nil,
                    isVerified: true,
                    lastSeen: nil,
                    identityKeyFingerprint: nil,
                    status: .offline,
                    isLocalUser: false
                ),
            ],
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            disappearingMessagesDuration: nil,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func makeMessage(id: String, conversationId: String, timestamp: Date) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: "local-user",
            timestamp: timestamp,
            content: .text("hello \(id)"),
            status: .sent,
            isOutgoing: true,
            replyToMessageId: nil,
            expiresAt: nil
        )
    }
}
