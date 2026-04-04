import Foundation
import GRDB

/// Protocol for local database operations.
protocol LocalDatabaseProtocol: AnyObject, Sendable {
    // MARK: - Messages

    func saveMessage(_ message: Message) async throws
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message]
    func deleteMessage(id: String) async throws
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck]
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws

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

/// GRDB-backed local database with encrypted SQLite storage.
/// Thread-safe via GRDB's internal WAL-mode serialization.
final class LocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    private let dbPool: DatabasePool

    /// Initialize with a database file path. Creates the DB and runs migrations.
    init(
        path: String? = nil,
        passphraseProvider: @escaping @Sendable () throws -> String
    ) {
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let dbDir = appSupport.appendingPathComponent("SanchrDB", isDirectory: true)
            try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

            // Set iOS Data Protection: complete protection until first unlock
            try? (dbDir as NSURL).setResourceValue(
                URLFileProtection.completeUntilFirstUserAuthentication,
                forKey: .fileProtectionKey
            )

            dbPath = dbDir.appendingPathComponent("sanchr.sqlite").path
        }

        var config = Configuration()
        #if DEBUG
        // Log SQL in debug for development visibility
        // config.prepareDatabase { db in db.trace { print("SQL: \($0)") } }
        #endif

        do {
            config.prepareDatabase { db in
                try db.usePassphrase(passphraseProvider())
            }

            dbPool = try Self.openDatabase(
                at: dbPath,
                configuration: config,
                passphraseProvider: passphraseProvider
            )
            try DatabaseSchema.migrator.migrate(dbPool)
            SanchrLogger.persistence.info("GRDB database initialized at \(dbPath)")
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    private static func openDatabase(
        at path: String,
        configuration: Configuration,
        passphraseProvider: @escaping @Sendable () throws -> String
    ) throws -> DatabasePool {
        do {
            return try DatabasePool(path: path, configuration: configuration)
        } catch {
            guard FileManager.default.fileExists(atPath: path),
                  try canOpenPlaintextDatabase(at: path)
            else {
                throw error
            }

            SanchrLogger.persistence.warning("Migrating existing plaintext database to SQLCipher")
            try migratePlaintextDatabase(at: path, passphraseProvider: passphraseProvider)
            return try DatabasePool(path: path, configuration: configuration)
        }
    }

    private static func canOpenPlaintextDatabase(at path: String) throws -> Bool {
        do {
            let plaintextDatabase = try DatabaseQueue(path: path)
            try plaintextDatabase.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
            }
            return true
        } catch {
            return false
        }
    }

    private static func migratePlaintextDatabase(
        at path: String,
        passphraseProvider: @escaping @Sendable () throws -> String
    ) throws {
        let fileManager = FileManager.default
        let encryptedPath = path + ".encrypted"
        try cleanupSidecarFiles(for: encryptedPath)
        try? fileManager.removeItem(atPath: encryptedPath)

        let plaintextDatabase = try DatabaseQueue(path: path)
        let passphrase = try passphraseProvider()

        try plaintextDatabase.writeWithoutTransaction { db in
            try db.execute(
                sql: "ATTACH DATABASE ? AS encrypted KEY ?",
                arguments: [encryptedPath, passphrase]
            )
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
        }

        try cleanupSidecarFiles(for: path)
        try fileManager.removeItem(atPath: path)
        try moveDatabaseFiles(from: encryptedPath, to: path)

        try? (URL(fileURLWithPath: path) as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
    }

    private static func cleanupSidecarFiles(for path: String) throws {
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let sidecarPath = path + suffix
            if fileManager.fileExists(atPath: sidecarPath) {
                try fileManager.removeItem(atPath: sidecarPath)
            }
        }
    }

    private static func moveDatabaseFiles(from sourcePath: String, to destinationPath: String) throws {
        let fileManager = FileManager.default
        try fileManager.moveItem(atPath: sourcePath, toPath: destinationPath)

        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = sourcePath + suffix
            let destinationSidecar = destinationPath + suffix
            guard fileManager.fileExists(atPath: sourceSidecar) else { continue }
            try? fileManager.removeItem(atPath: destinationSidecar)
            try fileManager.moveItem(atPath: sourceSidecar, toPath: destinationSidecar)
        }
    }

    // MARK: - Messages

    func saveMessage(_ message: Message) async throws {
        try await dbPool.write { db in
            try persistMessage(message, in: db, queueAck: false)
        }
        SanchrLogger.persistence.debug("Saved message \(message.id)")
    }

    func saveIncomingMessageAndQueueAck(_ message: Message) async throws {
        try await dbPool.write { db in
            try persistMessage(message, in: db, queueAck: true)
        }
        SanchrLogger.persistence.debug("Saved incoming message \(message.id) and queued ack")
    }

    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] {
        try await dbPool.read { db in
            var request = MessageRecord
                .filter(Column("conversationId") == conversationId)

            if let before {
                request = request.filter(Column("timestamp") < before)
            }

            let records = try request
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)

            return records.reversed().map { $0.toDomain() }
        }
    }

    func deleteMessage(id: String) async throws {
        try await dbPool.write { db in
            _ = try MessageRecord.deleteOne(db, key: id)
        }
    }

    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE message SET status = ? WHERE id = ?",
                arguments: [Message.DeliveryStatus.read.rawValue, upToMessageId]
            )
            try db.execute(
                sql: "UPDATE conversation SET unreadCount = 0 WHERE id = ?",
                arguments: [conversationId]
            )
        }
    }

    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE message SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] {
        try await dbPool.read { db in
            try PendingMessageAckRecord
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws {
        guard !acks.isEmpty else { return }

        try await dbPool.write { db in
            for ack in acks {
                _ = try PendingMessageAckRecord.deleteOne(
                    db,
                    key: ["conversationId": ack.conversationId, "messageId": ack.messageId]
                )
            }
        }
    }

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) async throws {
        let record = ConversationRecord(from: conversation)
        try await dbPool.write { db in
            // Upsert conversation
            try record.save(db, onConflict: Database.ConflictResolution.replace)

            // Sync participants: delete old, insert current
            try ConversationParticipantRecord
                .filter(Column("conversationId") == conversation.id)
                .deleteAll(db)

            for participant in conversation.participants {
                // Ensure user exists
                let userRecord = UserRecord(from: participant)
                try userRecord.save(db, onConflict: Database.ConflictResolution.replace)

                // Link participant
                let link = ConversationParticipantRecord(
                    conversationId: conversation.id,
                    userId: participant.id
                )
                try link.insert(db)
            }
        }
    }

    func fetchConversations() async throws -> [Conversation] {
        try await dbPool.read { db in
            let conversationRecords = try ConversationRecord
                .order(
                    Column("isPinned").desc,
                    SQL("COALESCE(lastMessageTimestamp, updatedAt) DESC").sqlExpression
                )
                .fetchAll(db)

            return try conversationRecords.map { convRecord in
                // Fetch participants for this conversation
                let participantIds = try ConversationParticipantRecord
                    .filter(Column("conversationId") == convRecord.id)
                    .fetchAll(db)
                    .map(\.userId)

                let users: [User]
                if participantIds.isEmpty {
                    users = []
                } else {
                    users = try UserRecord
                        .filter(participantIds.contains(Column("id")))
                        .fetchAll(db)
                        .map { $0.toDomain() }
                }

                return convRecord.toDomain(participants: users)
            }
        }
    }

    func deleteConversation(id: String) async throws {
        try await dbPool.write { db in
            // CASCADE handles messages and participants
            _ = try ConversationRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Contacts

    func saveContact(_ user: User) async throws {
        let record = UserRecord(from: user)
        try await dbPool.write { db in
            try record.save(db, onConflict: Database.ConflictResolution.replace)
        }
    }

    func fetchContacts() async throws -> [User] {
        try await dbPool.read { db in
            try UserRecord
                .filter(Column("isLocalUser") == false)
                .order(Column("displayName").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    func searchContacts(query: String) async throws -> [User] {
        guard !query.isEmpty else { return try await fetchContacts() }
        return try await dbPool.read { db in
            try UserRecord
                .filter(Column("isLocalUser") == false)
                .filter(Column("displayName").like("%\(query)%"))
                .order(Column("displayName").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    // MARK: - Vault

    func saveVaultItem(_ item: VaultItem) async throws {
        let record = VaultItemRecord(from: item)
        try await dbPool.write { db in
            try record.save(db, onConflict: Database.ConflictResolution.replace)
        }
    }

    func fetchVaultItems() async throws -> [VaultItem] {
        try await dbPool.read { db in
            try VaultItemRecord
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    func deleteVaultItem(id: String) async throws {
        try await dbPool.write { db in
            _ = try VaultItemRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Lifecycle

    func purgeAllData() async throws {
        try await dbPool.write { db in
            try PendingMessageAckRecord.deleteAll(db)
            try MessageRecord.deleteAll(db)
            try ConversationParticipantRecord.deleteAll(db)
            try ConversationRecord.deleteAll(db)
            try UserRecord.deleteAll(db)
            try VaultItemRecord.deleteAll(db)
        }
        SanchrLogger.persistence.warning("All local data purged")
    }

    private func persistMessage(_ message: Message, in db: Database, queueAck: Bool) throws {
        let record = MessageRecord(from: message)
        let existing = try MessageRecord.fetchOne(db, key: message.id)
        let shouldIncrementUnread = existing == nil && !message.isOutgoing

        try record.save(db, onConflict: Database.ConflictResolution.replace)

        if queueAck {
            let ackRecord = PendingMessageAckRecord(
                from: PendingMessageAck(
                    conversationId: message.conversationId,
                    messageId: message.id,
                    createdAt: Date()
                )
            )
            try ackRecord.save(db, onConflict: Database.ConflictResolution.replace)
        }

        try db.execute(
            sql: """
                UPDATE conversation
                SET
                    updatedAt = CASE
                        WHEN lastMessageTimestamp IS NULL OR lastMessageTimestamp <= ? THEN ?
                        ELSE updatedAt
                    END,
                    lastMessageId = CASE
                        WHEN lastMessageTimestamp IS NULL OR lastMessageTimestamp <= ? THEN ?
                        ELSE lastMessageId
                    END,
                    lastMessageContent = CASE
                        WHEN lastMessageTimestamp IS NULL OR lastMessageTimestamp <= ? THEN ?
                        ELSE lastMessageContent
                    END,
                    lastMessageTimestamp = CASE
                        WHEN lastMessageTimestamp IS NULL OR lastMessageTimestamp <= ? THEN ?
                        ELSE lastMessageTimestamp
                    END,
                    lastMessageSenderId = CASE
                        WHEN lastMessageTimestamp IS NULL OR lastMessageTimestamp <= ? THEN ?
                        ELSE lastMessageSenderId
                    END,
                    lastMessageStatus = CASE
                        WHEN lastMessageTimestamp IS NULL OR lastMessageTimestamp <= ? THEN ?
                        ELSE lastMessageStatus
                    END,
                    unreadCount = unreadCount + ?
                WHERE id = ?
                """,
            arguments: [
                message.timestamp,
                message.timestamp,
                message.timestamp,
                message.id,
                message.timestamp,
                MessageRecord.encodeContent(message.content),
                message.timestamp,
                message.timestamp,
                message.timestamp,
                message.senderId,
                message.timestamp,
                message.status.rawValue,
                shouldIncrementUnread ? 1 : 0,
                message.conversationId,
            ]
        )
    }
}
