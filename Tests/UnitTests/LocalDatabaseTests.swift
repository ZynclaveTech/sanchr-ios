import Foundation
import GRDB
import XCTest
import SanchrShared

@testable import Sanchr

final class LocalDatabaseTests: XCTestCase {
    private final class PassphraseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String

        init(_ value: String) {
            self.value = value
        }

        func read() -> String {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ newValue: String) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    func testFetchMessagesHonorsBeforeCursorAndReturnsAscendingOrder() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
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
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })

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

    func testMarkConversationAsReadMarksOnlyIncomingMessagesUpToTarget() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let conversation = makeConversation(id: "conversation-read-range", unreadCount: 2)

        try await database.saveConversation(conversation)

        let olderIncoming = makeMessage(
            id: "older-incoming",
            conversationId: conversation.id,
            timestamp: baseDate,
            senderId: "remote-user",
            status: .delivered,
            isOutgoing: false
        )
        let outgoing = makeMessage(
            id: "outgoing-middle",
            conversationId: conversation.id,
            timestamp: baseDate.addingTimeInterval(30),
            senderId: "local-user",
            status: .sent,
            isOutgoing: true
        )
        let latestIncoming = makeMessage(
            id: "latest-incoming",
            conversationId: conversation.id,
            timestamp: baseDate.addingTimeInterval(60),
            senderId: "remote-user",
            status: .delivered,
            isOutgoing: false
        )

        try await database.saveMessage(olderIncoming)
        try await database.saveMessage(outgoing)
        try await database.saveMessage(latestIncoming)

        try await database.markConversationAsRead(
            conversationId: conversation.id,
            upToMessageId: latestIncoming.id
        )

        let messages = try await database.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 10
        )
        let statusById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.status) })
        XCTAssertEqual(statusById[olderIncoming.id], .read)
        XCTAssertEqual(statusById[outgoing.id], .sent)
        XCTAssertEqual(statusById[latestIncoming.id], .read)

        let fetched = try await database.fetchConversation(id: conversation.id)
        XCTAssertEqual(fetched?.unreadCount, 0)
        XCTAssertEqual(fetched?.lastMessage?.id, latestIncoming.id)
        XCTAssertEqual(fetched?.lastMessage?.status, .read)
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

        let encryptedDatabase = try LocalDatabase(path: path, passphraseProvider: { "migrated-passphrase" })
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

    func testEncryptedDatabaseReopensWithSamePassphraseAcrossLaunches() async throws {
        let path = makeTemporaryDatabasePath()
        let conversation = makeConversation(id: "conversation-reopen")
        let message = makeMessage(
            id: "message-reopen",
            conversationId: conversation.id,
            timestamp: Date(timeIntervalSince1970: 1_750_000_900)
        )

        do {
            let database = try LocalDatabase(path: path, passphraseProvider: { "stable-passphrase" })
            try await database.saveConversation(conversation)
            try await database.saveMessage(message)
        }

        let reopened = try LocalDatabase(path: path, passphraseProvider: { "stable-passphrase" })
        let messages = try await reopened.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 10
        )

        XCTAssertEqual(messages.map(\.id), ["message-reopen"])
    }

    func testIncomingMessageReplayDoesNotDuplicateUnreadCountOrAckQueue() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        let conversation = makeConversation(id: "conversation-4")

        try await database.saveConversation(conversation)

        let incomingMessage = Message(
            id: "incoming-1",
            conversationId: conversation.id,
            senderId: "remote-user",
            timestamp: Date(timeIntervalSince1970: 1_750_001_000),
            content: .text("hello again"),
            status: .delivered,
            isOutgoing: false
        )

        try await database.saveIncomingMessageAndQueueAck(incomingMessage)
        try await database.saveIncomingMessageAndQueueAck(incomingMessage)

        let messages = try await database.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 10
        )
        let conversations = try await database.fetchConversations()
        let pendingAcks = try await database.fetchPendingMessageAcks(limit: 10)

        XCTAssertEqual(messages.map(\.id), ["incoming-1"])
        XCTAssertEqual(conversations.first?.unreadCount, 1)
        XCTAssertEqual(pendingAcks.count, 1)
        XCTAssertEqual(pendingAcks.first?.messageId, "incoming-1")
    }

    func testMetadataOnlyConversationSaveDoesNotWipeLocalPreviewOrUnreadState() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        let conversation = makeConversation(id: "conversation-4b")

        try await database.saveConversation(conversation)

        let incomingMessage = Message(
            id: "incoming-preview-1",
            conversationId: conversation.id,
            senderId: "remote-user",
            timestamp: Date(timeIntervalSince1970: 1_750_001_050),
            content: .text("preview should survive"),
            status: .delivered,
            isOutgoing: false
        )

        try await database.saveIncomingMessageAndQueueAck(incomingMessage)

        let serverMetadataOnlyConversation = Conversation(
            id: conversation.id,
            participants: conversation.participants,
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            disappearingMessagesDuration: nil,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )

        try await database.saveConversation(serverMetadataOnlyConversation)

        let fetchedConversation = try await database.fetchConversation(id: conversation.id)
        let storedConversation = try XCTUnwrap(fetchedConversation)
        XCTAssertEqual(storedConversation.lastMessage?.id, incomingMessage.id)
        if case .text(let text)? = storedConversation.lastMessage?.content {
            XCTAssertEqual(text, "preview should survive")
        } else {
            XCTFail("Expected stored preview text to survive metadata-only save")
        }
        XCTAssertEqual(storedConversation.unreadCount, 1)
    }

    func testPurgeAllDataRecreatesEncryptedDatabaseWithUpdatedPassphrase() async throws {
        let path = makeTemporaryDatabasePath()
        let passphrase = PassphraseBox("initial-passphrase")
        let database = try LocalDatabase(path: path, passphraseProvider: { passphrase.read() })
        let conversation = makeConversation(id: "conversation-5")

        try await database.saveConversation(conversation)
        try await database.saveMessage(
            makeMessage(
                id: "message-before-purge",
                conversationId: conversation.id,
                timestamp: Date(timeIntervalSince1970: 1_750_001_500)
            )
        )

        passphrase.write("rotated-passphrase")
        try await database.purgeAllData()

        let conversations = try await database.fetchConversations()
        let messages = try await database.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 10
        )

        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(messages.isEmpty)

        try await database.saveConversation(conversation)

        do {
            let plainDatabase = try DatabaseQueue(path: path)
            _ = try await plainDatabase.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
            }
            XCTFail("Expected recreated encrypted database to reject plaintext reads")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testExistingDatabaseWithoutStoredSecretReturnsControlledError() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        try await database.saveConversation(makeConversation(id: "conversation-6"))

        let storage = MockSecureStorage()
        let deviceSecrets = DeviceSecretProvider(secureStorage: storage)
        let keyProvider = LocalDatabaseKeyProvider(secureStorage: storage, deviceSecrets: deviceSecrets)

        do {
            _ = try LocalDatabase(path: path, keyProvider: keyProvider)
            XCTFail("Expected controlled local data unavailable error")
        } catch let error as AppError {
            guard case .localDataUnavailable = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testExistingEncryptedDatabaseWithWrongPassphraseReturnsControlledError() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "correct-passphrase" })
        try await database.saveConversation(makeConversation(id: "conversation-7"))

        do {
            _ = try LocalDatabase(path: path, passphraseProvider: { "wrong-passphrase" })
            XCTFail("Expected controlled local data unavailable error")
        } catch let error as AppError {
            guard case .localDataUnavailable = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testPersistedFallbackPassphraseAllowsReopenWhenDeviceSecretIsMissing() async throws {
        let path = makeTemporaryDatabasePath()
        let storage = MockSecureStorage()
        let deviceSecrets = DeviceSecretProvider(secureStorage: storage)
        let keyProvider = LocalDatabaseKeyProvider(secureStorage: storage, deviceSecrets: deviceSecrets)

        let database = try LocalDatabase(path: path, keyProvider: keyProvider)
        try await database.saveConversation(makeConversation(id: "conversation-8"))

        let persistedFallback = try XCTUnwrap(storage.databaseKey)
        XCTAssertFalse(persistedFallback.isEmpty)

        storage.deviceMasterSecret = nil

        let reopened = try LocalDatabase(path: path, keyProvider: keyProvider)
        let conversations = try await reopened.fetchConversations()

        XCTAssertEqual(conversations.map(\.id), ["conversation-8"])
    }

    #if targetEnvironment(simulator)
    func testSimulatorMirrorAllowsReopenWhenAllKeychainSecretsAreMissing() async throws {
        let path = makeTemporaryDatabasePath()
        let storage = MockSecureStorage()
        let deviceSecrets = DeviceSecretProvider(secureStorage: storage)
        let keyProvider = LocalDatabaseKeyProvider(secureStorage: storage, deviceSecrets: deviceSecrets)

        let database = try LocalDatabase(path: path, keyProvider: keyProvider)
        try await database.saveConversation(makeConversation(id: "conversation-9"))

        storage.deviceMasterSecret = nil
        storage.databaseKey = nil

        let reopened = try LocalDatabase(path: path, keyProvider: keyProvider)
        let conversations = try await reopened.fetchConversations()

        XCTAssertEqual(conversations.map(\.id), ["conversation-9"])
    }
    #endif

    func testBackupSnapshotRestoreRoundTripsConversationsAndMessages() async throws {
        let sourcePath = makeTemporaryDatabasePath()
        let sourceDatabase = try LocalDatabase(path: sourcePath, passphraseProvider: { "source-passphrase" })
        let conversation = makeConversation(id: "conversation-backup")
        let message = makeMessage(
            id: "message-backup",
            conversationId: conversation.id,
            timestamp: Date(timeIntervalSince1970: 1_750_002_000)
        )

        try await sourceDatabase.saveConversation(conversation)
        try await sourceDatabase.saveMessage(message)

        let snapshot = try await sourceDatabase.exportBackupSnapshot(
            currentUserId: "local-user",
            fingerprint: "test-fingerprint"
        )

        let restorePath = makeTemporaryDatabasePath()
        let restoredDatabase = try LocalDatabase(path: restorePath, passphraseProvider: { "restore-passphrase" })
        try await restoredDatabase.restoreBackupSnapshot(
            snapshot,
            currentUserId: "local-user",
            localFingerprint: "test-fingerprint"
        )

        let restoredConversations = try await restoredDatabase.fetchConversations()
        let restoredMessages = try await restoredDatabase.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 10
        )

        XCTAssertEqual(restoredConversations.map(\.id), ["conversation-backup"])
        XCTAssertEqual(restoredConversations.first?.lastMessage?.id, "message-backup")
        XCTAssertEqual(restoredMessages.map(\.id), ["message-backup"])
    }

    private func makeTemporaryDatabasePath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sanchr-tests.sqlite").path
    }

    private func makeConversation(id: String, unreadCount: Int = 0) -> Conversation {
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
            unreadCount: unreadCount,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            disappearingMessagesDuration: nil,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func makeMessage(
        id: String,
        conversationId: String,
        timestamp: Date,
        senderId: String = "local-user",
        status: Message.DeliveryStatus = .sent,
        isOutgoing: Bool = true
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: timestamp,
            content: .text("hello \(id)"),
            status: status,
            isOutgoing: isOutgoing,
            replyToMessageId: nil,
            expiresAt: nil
        )
    }

    // MARK: - Presence write-through

    func testUpdateUserPresencePersistsStatusAndLastSeen() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })

        let seeded = User(
            id: "peer-1",
            phoneNumber: "+15550001000",
            displayName: "Peer One",
            avatarURL: nil,
            bio: nil,
            isVerified: false,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline,
            isLocalUser: false
        )
        try await database.saveContact(seeded)

        let lastSeen = Date(timeIntervalSince1970: 1_750_000_500)
        try await database.updateUserPresence(
            userId: "peer-1",
            status: .online,
            lastSeen: lastSeen
        )

        let contacts = try await database.fetchContacts()
        let stored = contacts.first(where: { $0.id == "peer-1" })
        XCTAssertEqual(stored?.status, .online)
        XCTAssertEqual(stored?.lastSeen, lastSeen)
    }

    func testUpdateUserPresenceClearsLastSeenWhenNil() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })

        let seeded = User(
            id: "peer-2",
            phoneNumber: "+15550001001",
            displayName: "Peer Two",
            avatarURL: nil,
            bio: nil,
            isVerified: false,
            lastSeen: Date(timeIntervalSince1970: 1_750_000_000),
            identityKeyFingerprint: nil,
            status: .offline,
            isLocalUser: false
        )
        try await database.saveContact(seeded)

        try await database.updateUserPresence(
            userId: "peer-2",
            status: .online,
            lastSeen: nil
        )

        let contacts = try await database.fetchContacts()
        let stored = contacts.first(where: { $0.id == "peer-2" })
        XCTAssertEqual(stored?.status, .online)
        XCTAssertNil(stored?.lastSeen, "Online users should have lastSeen cleared")
    }

    // MARK: - Conversation denorm refresh

    func testConversationLastMessageStatusUpdatesWhenMessageIdMatches() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })

        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let conversation = makeConversation(id: "conv-denorm-1")
        try await database.saveConversation(conversation)

        let message = makeMessage(
            id: "msg-current",
            conversationId: conversation.id,
            timestamp: baseDate
        )
        try await database.saveMessage(message)

        // The denormalized lastMessageStatus starts as .sent (from the
        // makeMessage helper).
        try await database.updateConversationLastMessageStatusIfMatches(
            conversationId: conversation.id,
            messageId: "msg-current",
            status: .read
        )

        let fetched = try await database.fetchConversation(id: conversation.id)
        XCTAssertEqual(
            fetched?.lastMessage?.status,
            .read,
            "Matching message id should promote the denormalized status"
        )
    }

    func testConversationLastMessageStatusSkipsWhenMessageIdDiffers() async throws {
        let path = makeTemporaryDatabasePath()
        let database = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })

        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let conversation = makeConversation(id: "conv-denorm-2")
        try await database.saveConversation(conversation)

        let currentMessage = makeMessage(
            id: "msg-latest",
            conversationId: conversation.id,
            timestamp: baseDate.addingTimeInterval(60)
        )
        try await database.saveMessage(currentMessage)

        // Receipt for an OLDER message that was replaced by the latest
        // one. The denorm must NOT regress — the current last message
        // is still "sent" since that's the ground truth.
        try await database.updateConversationLastMessageStatusIfMatches(
            conversationId: conversation.id,
            messageId: "msg-older-and-gone",
            status: .read
        )

        let fetched = try await database.fetchConversation(id: conversation.id)
        XCTAssertEqual(
            fetched?.lastMessage?.status,
            .sent,
            "Denorm must not regress when the receipt targets a non-current message"
        )
    }
}
