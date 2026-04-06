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
    func searchMessages(conversationId: String, query: String) async throws -> [Message]

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) async throws
    func fetchConversation(id: String) async throws -> Conversation?
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

    // MARK: - Access Keys (Media Forward Secrecy)

    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry?
    func deleteAccessKeyEntry(mediaId: String) async throws
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int
    func deleteAllAccessKeyEntries() async throws

    // MARK: - Lifecycle

    func hasLocalHistory() async throws -> Bool
    func exportBackupSnapshot(currentUserId: String?) async throws -> BackupArchiveSnapshot
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?) async throws
    func purgeAllData() async throws
}

/// GRDB-backed local database with encrypted SQLite storage.
/// Thread-safe via GRDB's internal WAL-mode serialization.
final class LocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    private enum BootstrapState {
        case freshEncrypted
        case migratedPlaintext
        case reopenedEncrypted
    }

    private var dbPool: DatabasePool
    private let dbPath: String
    private let keyProvider: LocalDatabaseKeyProviderProtocol

    /// Initialize with a database file path. Creates the DB and runs migrations.
    init(
        path: String? = nil,
        keyProvider: LocalDatabaseKeyProviderProtocol
    ) throws {
        let dbPath = Self.resolveDatabasePath(customPath: path)
        self.dbPath = dbPath
        self.keyProvider = keyProvider
        do {
            let passphrase = try Self.resolvePassphrase(for: dbPath, keyProvider: keyProvider)
            let bootstrapState = try Self.bootstrapDatabase(at: dbPath, passphrase: passphrase)
            let pool = try Self.makeEncryptedDatabasePool(at: dbPath, passphrase: passphrase)
            try Self.verifyReadableDatabase(pool)
            try DatabaseSchema.migrator.migrate(pool)
            try keyProvider.persistResolvedPassphrase(passphrase, forDatabaseAt: dbPath)
            dbPool = pool

            switch bootstrapState {
            case .freshEncrypted:
                SanchrLogger.persistence.info("Encrypted database created at \(dbPath)")
            case .migratedPlaintext:
                SanchrLogger.persistence.info("Plaintext database migrated to SQLCipher at \(dbPath)")
            case .reopenedEncrypted:
                SanchrLogger.persistence.info("Encrypted database reopened at \(dbPath)")
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw Self.mappedBootstrapError(path: dbPath, error: error)
        }
    }

    convenience init(
        path: String? = nil,
        passphraseProvider: @escaping @Sendable () throws -> String
    ) throws {
        try self.init(
            path: path,
            keyProvider: ClosureLocalDatabaseKeyProvider(passphraseProvider: passphraseProvider)
        )
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

    func searchMessages(conversationId: String, query: String) async throws -> [Message] {
        try await dbPool.read { db in
            let pattern = "%\(query)%"
            let records = try MessageRecord
                .filter(Column("conversationId") == conversationId)
                .filter(Column("contentJSON").like(pattern))
                .order(Column("timestamp").desc)
                .limit(50)
                .fetchAll(db)
            return records.map { $0.toDomain() }
        }
    }

    // MARK: - Conversations

    func saveConversation(_ conversation: Conversation) async throws {
        try await dbPool.write { db in
            var record = ConversationRecord(from: conversation)
            if let existingRecord = try ConversationRecord.fetchOne(db, key: conversation.id) {
                record = mergeConversationRecord(existing: existingRecord, incoming: record)
            }

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

    func fetchConversation(id: String) async throws -> Conversation? {
        try await dbPool.read { db in
            guard let convRecord = try ConversationRecord.fetchOne(db, key: id) else {
                return nil
            }

            let participantIds = try ConversationParticipantRecord
                .filter(Column("conversationId") == id)
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

    // MARK: - Access Keys (Media Forward Secrecy)

    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws {
        let record = AccessKeyRecord(entry: entry)
        try await dbPool.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? {
        try await dbPool.read { db in
            guard let record = try AccessKeyRecord
                .filter(AccessKeyRecord.Columns.mediaId == mediaId)
                .fetchOne(db)
            else {
                return nil
            }
            return record.toEntry()
        }
    }

    func deleteAccessKeyEntry(mediaId: String) async throws {
        try await dbPool.write { db in
            _ = try AccessKeyRecord
                .filter(AccessKeyRecord.Columns.mediaId == mediaId)
                .deleteAll(db)
        }
    }

    func purgeAccessKeyEntries(olderThan cutoff: Date) async throws -> Int {
        try await dbPool.write { db in
            try AccessKeyRecord
                .filter(AccessKeyRecord.Columns.createdAt < cutoff)
                .deleteAll(db)
        }
    }

    func deleteAllAccessKeyEntries() async throws {
        try await dbPool.write { db in
            _ = try AccessKeyRecord.deleteAll(db)
        }
    }

    // MARK: - Lifecycle

    func hasLocalHistory() async throws -> Bool {
        try await dbPool.read { db in
            let messageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
            let conversationCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
            return messageCount > 0 || conversationCount > 0
        }
    }

    func exportBackupSnapshot(currentUserId: String?) async throws -> BackupArchiveSnapshot {
        try await dbPool.read { db in
            let userRecords = try UserRecord.fetchAll(db)
            let conversationRecords = try ConversationRecord.fetchAll(db)
            let messageRecords = try MessageRecord.fetchAll(db)
            let vaultRecords = try VaultItemRecord.fetchAll(db)

            let contacts = userRecords.map { record in
                BackupArchiveContactFrame(
                    id: record.id,
                    userId: record.isLocalUser ? currentUserId ?? record.id : record.id,
                    phoneNumber: record.phoneNumber,
                    displayName: record.displayName,
                    avatarURL: record.avatarURL,
                    bio: record.bio,
                    isVerified: record.isVerified,
                    lastSeenMs: record.lastSeen.map { Int64($0.timeIntervalSince1970 * 1000) },
                    status: record.status,
                    isLocalUser: record.isLocalUser,
                    isRegistered: record.isVerified,
                    isBlocked: false,
                    isFavorite: false,
                    lastSyncedAtMs: nil
                )
            }

            let conversations = try conversationRecords.map { record in
                let participantIDs = try ConversationParticipantRecord
                    .filter(Column("conversationId") == record.id)
                    .fetchAll(db)
                    .map(\.userId)
                let lastContent = record.lastMessageContent.flatMap(BackupArchiveContentCodec.decodeStoredContent)

                return BackupArchiveConversationFrame(
                    id: record.id,
                    conversationType: record.type,
                    title: nil,
                    avatarURL: nil,
                    participantIDs: participantIDs,
                    lastMessageID: record.lastMessageId,
                    lastMessagePreview: lastContent?.preview,
                    lastMessageTimestampMs: record.lastMessageTimestamp.map { Int64($0.timeIntervalSince1970 * 1000) },
                    lastMessageSenderID: record.lastMessageSenderId,
                    lastMessageStatus: record.lastMessageStatus,
                    lastMessageContentType: lastContent?.type,
                    lastMessageContentBody: lastContent?.body,
                    unreadCount: record.unreadCount,
                    isPinned: record.isPinned,
                    isMuted: record.isMuted,
                    isArchived: record.isArchived,
                    disappearingDurationMs: record.disappearingMessagesDuration.map { Int64($0 * 1000) },
                    createdAtMs: Int64(record.createdAt.timeIntervalSince1970 * 1000),
                    updatedAtMs: Int64(record.updatedAt.timeIntervalSince1970 * 1000)
                )
            }

            let messages = messageRecords.map { record in
                let content = BackupArchiveContentCodec.decodeStoredContent(record.contentJSON)
                    ?? ("text", "", "")
                return BackupArchiveMessageFrame(
                    id: record.id,
                    conversationID: record.conversationId,
                    senderID: record.senderId,
                    timestampMs: Int64(record.timestamp.timeIntervalSince1970 * 1000),
                    contentType: content.type,
                    contentBody: content.body,
                    previewText: content.preview,
                    status: record.status,
                    isOutgoing: record.isOutgoing,
                    replyToMessageID: record.replyToMessageId,
                    expiresAtMs: record.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                    isDeleted: false
                )
            }

            let vaultItems = vaultRecords.map { record in
                BackupArchiveVaultItemFrame(
                    id: record.id,
                    name: record.name,
                    itemType: record.type,
                    sizeBytes: record.sizeBytes,
                    encryptionKeyBase64: record.encryptionKey.base64EncodedString(),
                    encryptionIVBase64: record.encryptionIV.base64EncodedString(),
                    encryptedThumbnailURL: record.encryptedThumbnailURL,
                    createdAtMs: Int64(record.createdAt.timeIntervalSince1970 * 1000),
                    updatedAtMs: Int64(record.updatedAt.timeIntervalSince1970 * 1000),
                    isCachedLocally: record.isCachedLocally,
                    remoteURL: record.remoteURL,
                    localURL: record.localURL
                )
            }

            let info = BackupArchiveInfoFrame(
                formatVersion: BackupArchive.formatVersion,
                exportedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                platform: "ios",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                contactCount: contacts.count,
                conversationCount: conversations.count,
                messageCount: messages.count,
                vaultItemCount: vaultItems.count
            )

            return BackupArchiveSnapshot(
                info: info,
                contacts: contacts,
                conversations: conversations,
                messages: messages,
                vaultItems: vaultItems
            )
        }
    }

    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?) async throws {
        let tempPath = "\(dbPath).restore-\(UUID().uuidString.lowercased())"
        try Self.removeDatabaseArtifacts(at: tempPath)

        let passphrase = try Self.resolvePassphrase(for: dbPath, keyProvider: keyProvider)
        let tempQueue = try Self.makeEncryptedDatabaseQueue(at: tempPath, passphrase: passphrase)
        do {
            try Self.verifyReadableDatabase(tempQueue)
            try DatabaseSchema.migrator.migrate(tempQueue)

            try await tempQueue.write { db in
                for contact in snapshot.contacts {
                    let userID = contact.userId?.isEmpty == false ? contact.userId! : contact.id
                    let isLocalUser = contact.isLocalUser || (currentUserId != nil && userID == currentUserId)
                    let record = UserRecord(
                        id: userID,
                        phoneNumber: contact.phoneNumber,
                        displayName: contact.displayName,
                        avatarURL: contact.avatarURL,
                        bio: contact.bio,
                        isVerified: contact.isVerified || contact.isRegistered,
                        lastSeen: contact.lastSeenMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                        identityKeyFingerprint: nil,
                        status: contact.status,
                        isLocalUser: isLocalUser
                    )
                    try record.save(db, onConflict: .replace)
                }

                if let currentUserId,
                   try UserRecord.fetchOne(db, key: currentUserId) == nil
                {
                    let localUser = UserRecord(
                        id: currentUserId,
                        phoneNumber: "",
                        displayName: "You",
                        avatarURL: nil,
                        bio: nil,
                        isVerified: true,
                        lastSeen: nil,
                        identityKeyFingerprint: nil,
                        status: User.Status.offline.rawValue,
                        isLocalUser: true
                    )
                    try localUser.save(db, onConflict: .replace)
                }

                for conversation in snapshot.conversations {
                    let record = ConversationRecord(
                        id: conversation.id,
                        type: conversation.conversationType,
                        unreadCount: conversation.unreadCount,
                        isPinned: conversation.isPinned,
                        isMuted: conversation.isMuted,
                        isArchived: conversation.isArchived,
                        disappearingMessagesDuration: conversation.disappearingDurationMs.map { Double($0) / 1000.0 },
                        createdAt: Date(timeIntervalSince1970: TimeInterval(conversation.createdAtMs) / 1000),
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(conversation.updatedAtMs) / 1000),
                        lastMessageId: conversation.lastMessageID,
                        lastMessageContent: {
                            guard let contentType = conversation.lastMessageContentType,
                                  let contentBody = conversation.lastMessageContentBody
                            else { return nil }
                            return BackupArchiveContentCodec.encodeStoredContent(
                                type: contentType,
                                body: contentBody,
                                preview: conversation.lastMessagePreview
                            )
                        }(),
                        lastMessageTimestamp: conversation.lastMessageTimestampMs.map {
                            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                        },
                        lastMessageSenderId: conversation.lastMessageSenderID,
                        lastMessageStatus: conversation.lastMessageStatus
                    )
                    try record.save(db, onConflict: .replace)

                    for participantID in conversation.participantIDs {
                        if try UserRecord.fetchOne(db, key: participantID) == nil {
                            let placeholder = UserRecord(
                                id: participantID,
                                phoneNumber: "",
                                displayName: participantID,
                                avatarURL: nil,
                                bio: nil,
                                isVerified: true,
                                lastSeen: nil,
                                identityKeyFingerprint: nil,
                                status: User.Status.offline.rawValue,
                                isLocalUser: participantID == currentUserId
                            )
                            try placeholder.save(db, onConflict: .replace)
                        }

                        try ConversationParticipantRecord(
                            conversationId: conversation.id,
                            userId: participantID
                        ).save(db, onConflict: .replace)
                    }
                }

                for message in snapshot.messages {
                    let record = MessageRecord(
                        id: message.id,
                        conversationId: message.conversationID,
                        senderId: message.senderID,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(message.timestampMs) / 1000),
                        contentJSON: BackupArchiveContentCodec.encodeStoredContent(
                            type: message.contentType,
                            body: message.contentBody,
                            preview: message.previewText
                        ) ?? MessageRecord.encodeContent(.text(message.previewText ?? message.contentBody)),
                        status: message.status,
                        isOutgoing: message.isOutgoing,
                        replyToMessageId: message.replyToMessageID,
                        expiresAt: message.expiresAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                    )
                    try record.save(db, onConflict: .replace)
                }

                for vaultItem in snapshot.vaultItems {
                    let record = VaultItemRecord(
                        id: vaultItem.id,
                        name: vaultItem.name,
                        type: vaultItem.itemType,
                        sizeBytes: vaultItem.sizeBytes,
                        encryptionKey: Data(base64Encoded: vaultItem.encryptionKeyBase64) ?? Data(),
                        encryptionIV: Data(base64Encoded: vaultItem.encryptionIVBase64) ?? Data(),
                        thumbnailData: nil,
                        encryptedThumbnailURL: vaultItem.encryptedThumbnailURL,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(vaultItem.createdAtMs) / 1000),
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(vaultItem.updatedAtMs) / 1000),
                        isCachedLocally: vaultItem.isCachedLocally,
                        remoteURL: vaultItem.remoteURL,
                        localURL: vaultItem.localURL
                    )
                    try record.save(db, onConflict: .replace)
                }
            }

            try tempQueue.close()
            try dbPool.close()
            try Self.removeSQLiteSidecars(for: dbPath)

            let originalURL = URL(fileURLWithPath: dbPath)
            let tempURL = URL(fileURLWithPath: tempPath)
            if FileManager.default.fileExists(atPath: dbPath) {
                _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: originalURL)
            }

            let restoredPool = try Self.makeEncryptedDatabasePool(at: dbPath, passphrase: passphrase)
            try Self.verifyReadableDatabase(restoredPool)
            try DatabaseSchema.migrator.migrate(restoredPool)
            dbPool = restoredPool
            SanchrLogger.persistence.info("Restored encrypted database from backup archive at \(self.dbPath)")
        } catch {
            try? tempQueue.close()
            try? Self.removeDatabaseArtifacts(at: tempPath)
            throw error
        }
    }

    func purgeAllData() async throws {
        try dbPool.close()
        try Self.removeDatabaseArtifacts(at: dbPath)
        let newPassphrase = try Self.resolvePassphrase(for: dbPath, keyProvider: keyProvider)
        let newPool = try Self.makeEncryptedDatabasePool(at: dbPath, passphrase: newPassphrase)
        try Self.verifyReadableDatabase(newPool)
        try DatabaseSchema.migrator.migrate(newPool)
        dbPool = newPool

        SanchrLogger.persistence.warning("Encrypted database reset at \(self.dbPath)")
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

    private func mergeConversationRecord(
        existing: ConversationRecord,
        incoming: ConversationRecord
    ) -> ConversationRecord {
        var merged = incoming
        merged.createdAt = min(existing.createdAt, incoming.createdAt)

        let shouldPreserveExistingPreview: Bool = {
            guard let existingTimestamp = existing.lastMessageTimestamp else { return false }
            guard let incomingTimestamp = incoming.lastMessageTimestamp else { return true }
            return existingTimestamp > incomingTimestamp
        }()

        if shouldPreserveExistingPreview {
            merged.lastMessageId = existing.lastMessageId
            merged.lastMessageContent = existing.lastMessageContent
            merged.lastMessageTimestamp = existing.lastMessageTimestamp
            merged.lastMessageSenderId = existing.lastMessageSenderId
            merged.lastMessageStatus = existing.lastMessageStatus
            merged.updatedAt = max(existing.updatedAt, incoming.updatedAt)
            merged.unreadCount = max(existing.unreadCount, incoming.unreadCount)
        } else {
            merged.updatedAt = max(existing.updatedAt, incoming.updatedAt)
        }

        return merged
    }

    private static func resolveDatabasePath(customPath: String?) -> String {
        if let customPath {
            return customPath
        }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dbDir = appSupport.appendingPathComponent("SanchrDB", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try? (dbDir as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )

        return dbDir.appendingPathComponent("sanchr.sqlite").path
    }

    static func destroyDatabaseFiles(customPath: String? = nil) throws {
        try removeDatabaseArtifacts(at: resolveDatabasePath(customPath: customPath))
    }

    private static func resolvePassphrase(
        for path: String,
        keyProvider: LocalDatabaseKeyProviderProtocol
    ) throws -> String {
        switch try keyProvider.resolveKeyResolution(forDatabaseAt: path) {
        case .passphrase(let passphrase):
            return passphrase
        case .missingSecretForExistingDatabase:
            let message =
                "Encrypted local data exists, but the device secret is unavailable. Reset local data to continue."
            SanchrLogger.persistence.error("\(message) path=\(path)")
            throw AppError.localDataUnavailable(reason: message)
        }
    }

    private static func bootstrapDatabase(at path: String, passphrase: String) throws
        -> BootstrapState
    {
        if !FileManager.default.fileExists(atPath: path) {
            return .freshEncrypted
        }

        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber,
            fileSize.int64Value == 0
        {
            try removeDatabaseArtifacts(at: path)
            return .freshEncrypted
        }

        if try isPlaintextDatabase(at: path) {
            try migratePlaintextDatabase(at: path, passphrase: passphrase)
            return .migratedPlaintext
        }

        return .reopenedEncrypted
    }

    private static func mappedBootstrapError(path: String, error: Error) -> Error {
        let message = error.localizedDescription.lowercased()
        if message.contains("file is not a database") {
            let reason =
                "Sanchr could not unlock its encrypted local data. Reset local data to continue."
            SanchrLogger.persistence.error(
                "Encrypted database open failed at \(path): \(error.localizedDescription)"
            )
            return AppError.localDataUnavailable(reason: reason)
        }

        SanchrLogger.persistence.error(
            "Encrypted database bootstrap failed at \(path): \(error.localizedDescription)"
        )
        return AppError.databaseError(reason: error.localizedDescription)
    }

    private static func makeEncryptedDatabasePool(at path: String, passphrase: String) throws
        -> DatabasePool
    {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
            guard try String.fetchOne(db, sql: "PRAGMA cipher_version") != nil else {
                throw NSError(
                    domain: "LocalDatabase",
                    code: 1001,
                    userInfo: [
                        NSLocalizedDescriptionKey: "GRDB is not linked against SQLCipher"
                    ]
                )
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try DatabasePool(path: path, configuration: config)
    }

    private static func makeEncryptedDatabaseQueue(at path: String, passphrase: String) throws
        -> DatabaseQueue
    {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
            guard try String.fetchOne(db, sql: "PRAGMA cipher_version") != nil else {
                throw NSError(
                    domain: "LocalDatabase",
                    code: 1001,
                    userInfo: [
                        NSLocalizedDescriptionKey: "GRDB is not linked against SQLCipher"
                    ]
                )
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try DatabaseQueue(path: path, configuration: config)
    }

    private static func verifyReadableDatabase(_ dbReader: any DatabaseReader) throws {
        _ = try dbReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
        }
    }

    private static func isPlaintextDatabase(at path: String) throws -> Bool {
        let headerLength = 16
        let expectedHeader = Data("SQLite format 3\0".utf8)
        let fileURL = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: headerLength) ?? Data()
        return header == expectedHeader
    }

    private static func migratePlaintextDatabase(at path: String, passphrase: String) throws {
        let migrationPath = "\(path).sqlcipher-migration"
        try removeDatabaseArtifacts(at: migrationPath)

        let sourceQueue = try DatabaseQueue(path: path)
        do {
            try sourceQueue.writeWithoutTransaction { db in
                let escapedMigrationPath = migrationPath.replacingOccurrences(of: "'", with: "''")
                let escapedPassphrase = passphrase.replacingOccurrences(of: "'", with: "''")

                try db.execute(
                    sql:
                        "ATTACH DATABASE '\(escapedMigrationPath)' AS encrypted KEY '\(escapedPassphrase)'"
                )
                try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
                try db.execute(sql: "DETACH DATABASE encrypted")
            }
        } catch {
            try? sourceQueue.close()
            try? removeDatabaseArtifacts(at: migrationPath)
            throw error
        }

        try sourceQueue.close()

        let encryptedQueue = try makeEncryptedDatabaseQueue(at: migrationPath, passphrase: passphrase)
        do {
            try verifyReadableDatabase(encryptedQueue)
            try encryptedQueue.close()
        } catch {
            try? encryptedQueue.close()
            try? removeDatabaseArtifacts(at: migrationPath)
            throw error
        }

        try removeSQLiteSidecars(for: path)

        let originalURL = URL(fileURLWithPath: path)
        let encryptedURL = URL(fileURLWithPath: migrationPath)
        _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: encryptedURL)
    }

    private static func removeDatabaseArtifacts(at path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        try removeSQLiteSidecars(for: path)
        #if targetEnvironment(simulator)
        let mirrorPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent(".sanchr-simulator-db-key")
            .path
        if FileManager.default.fileExists(atPath: mirrorPath) {
            try FileManager.default.removeItem(atPath: mirrorPath)
        }
        #endif
    }

    private static func removeSQLiteSidecars(for path: String) throws {
        let sidecars = ["-wal", "-shm"].map { path + $0 }
        for sidecar in sidecars where FileManager.default.fileExists(atPath: sidecar) {
            try FileManager.default.removeItem(atPath: sidecar)
        }
    }
}

private final class ClosureLocalDatabaseKeyProvider: LocalDatabaseKeyProviderProtocol, @unchecked Sendable {
    private let passphraseProvider: @Sendable () throws -> String

    init(passphraseProvider: @escaping @Sendable () throws -> String) {
        self.passphraseProvider = passphraseProvider
    }

    func resolveKeyResolution(forDatabaseAt path: String) throws -> LocalDatabaseKeyResolution {
        .passphrase(try passphraseProvider())
    }

    func persistResolvedPassphrase(_ passphrase: String, forDatabaseAt path: String) throws {}

    func resetDatabaseSecrets() throws {}
}

final class UnavailableLocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func saveMessage(_ message: Message) async throws { throw error }
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws { throw error }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { throw error }
    func deleteMessage(id: String) async throws { throw error }
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { throw error }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { throw error }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { throw error }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { throw error }
    func saveConversation(_ conversation: Conversation) async throws { throw error }
    func fetchConversation(id: String) async throws -> Conversation? { throw error }
    func fetchConversations() async throws -> [Conversation] { throw error }
    func deleteConversation(id: String) async throws { throw error }
    func saveContact(_ user: User) async throws { throw error }
    func fetchContacts() async throws -> [User] { throw error }
    func searchContacts(query: String) async throws -> [User] { throw error }
    func saveVaultItem(_ item: VaultItem) async throws { throw error }
    func fetchVaultItems() async throws -> [VaultItem] { throw error }
    func deleteVaultItem(id: String) async throws { throw error }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { throw error }
    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws { throw error }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { throw error }
    func deleteAccessKeyEntry(mediaId: String) async throws { throw error }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { throw error }
    func deleteAllAccessKeyEntries() async throws { throw error }
    func hasLocalHistory() async throws -> Bool { throw error }
    func exportBackupSnapshot(currentUserId: String?) async throws -> BackupArchiveSnapshot { throw error }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?) async throws { throw error }
    func purgeAllData() async throws { throw error }
}
