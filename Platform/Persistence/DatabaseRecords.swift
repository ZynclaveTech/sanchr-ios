import Foundation
import GRDB

// MARK: - User Record

struct UserRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "user"

    var id: String
    var phoneNumber: String
    var displayName: String
    var avatarURL: String?
    var bio: String?
    var isVerified: Bool
    var lastSeen: Date?
    var identityKeyFingerprint: String?
    var status: String
    var isLocalUser: Bool

    // MARK: - Domain Conversion

    init(from user: User) {
        self.id = user.id
        self.phoneNumber = user.phoneNumber
        self.displayName = user.displayName
        self.avatarURL = user.avatarURL?.absoluteString
        self.bio = user.bio
        self.isVerified = user.isVerified
        self.lastSeen = user.lastSeen
        self.identityKeyFingerprint = user.identityKeyFingerprint
        self.status = user.status.rawValue
        self.isLocalUser = user.isLocalUser
    }

    func toDomain() -> User {
        User(
            id: id,
            phoneNumber: phoneNumber,
            displayName: displayName,
            avatarURL: avatarURL.flatMap { URL(string: $0) },
            bio: bio,
            isVerified: isVerified,
            lastSeen: lastSeen,
            identityKeyFingerprint: identityKeyFingerprint,
            status: User.Status(rawValue: status) ?? .offline,
            isLocalUser: isLocalUser
        )
    }
}

// MARK: - Conversation Record

struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conversation"

    var id: String
    var type: String
    var unreadCount: Int
    var isPinned: Bool
    var isMuted: Bool
    var isArchived: Bool
    var disappearingMessagesDuration: Double?
    var createdAt: Date
    var updatedAt: Date
    // Denormalized last message
    var lastMessageId: String?
    var lastMessageContent: String?
    var lastMessageTimestamp: Date?
    var lastMessageSenderId: String?
    var lastMessageStatus: String?

    init(from conversation: Conversation) {
        self.id = conversation.id
        self.type = conversation.type.rawValue
        self.unreadCount = conversation.unreadCount
        self.isPinned = conversation.isPinned
        self.isMuted = conversation.isMuted
        self.isArchived = conversation.isArchived
        self.disappearingMessagesDuration = conversation.disappearingMessagesDuration
        self.createdAt = conversation.createdAt
        self.updatedAt = conversation.updatedAt

        if let lastMsg = conversation.lastMessage {
            self.lastMessageId = lastMsg.id
            self.lastMessageContent = Self.encodeContent(lastMsg.content)
            self.lastMessageTimestamp = lastMsg.timestamp
            self.lastMessageSenderId = lastMsg.senderId
            self.lastMessageStatus = lastMsg.status.rawValue
        }
    }

    func toDomain(participants: [User]) -> Conversation {
        var lastMessage: Message?
        if let msgId = lastMessageId,
           let contentJSON = lastMessageContent,
           let timestamp = lastMessageTimestamp,
           let senderId = lastMessageSenderId
        {
            let content = Self.decodeContent(contentJSON) ?? .text("")
            let status = Message.DeliveryStatus(rawValue: lastMessageStatus ?? "sent") ?? .sent
            lastMessage = Message(
                id: msgId,
                conversationId: id,
                senderId: senderId,
                timestamp: timestamp,
                content: content,
                status: status,
                isOutgoing: false // Not critical for list display
            )
        }

        return Conversation(
            id: id,
            participants: participants,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            isPinned: isPinned,
            isMuted: isMuted,
            isArchived: isArchived,
            type: Conversation.ConversationType(rawValue: type) ?? .oneToOne,
            disappearingMessagesDuration: disappearingMessagesDuration,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func encodeContent(_ content: Message.MessageContent) -> String? {
        guard let data = try? JSONEncoder().encode(content) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeContent(_ json: String) -> Message.MessageContent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Message.MessageContent.self, from: data)
    }
}

// MARK: - Conversation Participant Record

struct ConversationParticipantRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conversationParticipant"

    var conversationId: String
    var userId: String
}

// MARK: - Message Record

struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "message"

    var id: String
    var conversationId: String
    var senderId: String
    var timestamp: Date
    var contentJSON: String
    var status: String
    var isOutgoing: Bool
    var replyToMessageId: String?
    var expiresAt: Date?

    init(from message: Message) {
        self.id = message.id
        self.conversationId = message.conversationId
        self.senderId = message.senderId
        self.timestamp = message.timestamp
        self.contentJSON = Self.encodeContent(message.content)
        self.status = message.status.rawValue
        self.isOutgoing = message.isOutgoing
        self.replyToMessageId = message.replyToMessageId
        self.expiresAt = message.expiresAt
    }

    func toDomain() -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: timestamp,
            content: Self.decodeContent(contentJSON) ?? .text(""),
            status: Message.DeliveryStatus(rawValue: status) ?? .sent,
            isOutgoing: isOutgoing,
            replyToMessageId: replyToMessageId,
            expiresAt: expiresAt
        )
    }

    static func encodeContent(_ content: Message.MessageContent) -> String {
        guard let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private static func decodeContent(_ json: String) -> Message.MessageContent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Message.MessageContent.self, from: data)
    }
}

// MARK: - Vault Item Record

struct VaultItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "vaultItem"

    var id: String
    var name: String
    var type: String
    var sizeBytes: Int64
    var encryptionKey: Data
    var encryptionIV: Data
    var thumbnailData: Data?
    var encryptedThumbnailURL: String?
    var createdAt: Date
    var updatedAt: Date
    var isCachedLocally: Bool
    var remoteURL: String?
    var localURL: String?

    init(from item: VaultItem) {
        self.id = item.id
        self.name = item.name
        self.type = item.type.rawValue
        self.sizeBytes = item.sizeBytes
        self.encryptionKey = item.encryptionKey
        self.encryptionIV = item.encryptionIV
        self.thumbnailData = nil
        self.encryptedThumbnailURL = item.encryptedThumbnailURL?.absoluteString
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.isCachedLocally = item.isCachedLocally
        self.remoteURL = item.remoteURL?.absoluteString
        self.localURL = item.localURL?.absoluteString
    }

    func toDomain() -> VaultItem {
        VaultItem(
            id: id,
            name: name,
            type: VaultItem.VaultItemType(rawValue: type) ?? .document,
            sizeBytes: sizeBytes,
            encryptionKey: encryptionKey,
            encryptionIV: encryptionIV,
            thumbnailData: nil,
            encryptedThumbnailURL: encryptedThumbnailURL.flatMap { URL(string: $0) },
            createdAt: createdAt,
            updatedAt: updatedAt,
            isCachedLocally: isCachedLocally,
            remoteURL: remoteURL.flatMap { URL(string: $0) },
            localURL: localURL.flatMap { URL(string: $0) }
        )
    }
}
