import Foundation
import GRDB

// MARK: - User Record

public struct UserRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "user"

    public var id: String
    public var phoneNumber: String
    public var displayName: String
    public var avatarURL: String?
    public var bio: String?
    public var isVerified: Bool
    public var lastSeen: Date?
    public var identityKeyFingerprint: String?
    public var status: String
    public var isLocalUser: Bool
    public var profileKey: Data?

    // MARK: - Domain Conversion

    public init(from user: User) {
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
        // Coerce to nil if not exactly 32 bytes — avoids persisting a malformed key
        // that would silently degrade to a deterministic subkey in HKDF later.
        self.profileKey = user.profileKey.flatMap { $0.count == 32 ? $0 : nil }
    }

    public init(
        id: String,
        phoneNumber: String,
        displayName: String,
        avatarURL: String?,
        bio: String?,
        isVerified: Bool,
        lastSeen: Date?,
        identityKeyFingerprint: String?,
        status: String,
        isLocalUser: Bool,
        profileKey: Data? = nil
    ) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.isVerified = isVerified
        self.lastSeen = lastSeen
        self.identityKeyFingerprint = identityKeyFingerprint
        self.status = status
        self.isLocalUser = isLocalUser
        self.profileKey = profileKey
    }

    public func toDomain() -> User {
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
            isLocalUser: isLocalUser,
            profileKey: profileKey
        )
    }
}

// MARK: - Conversation Record

public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "conversation"

    public var id: String
    public var type: String
    public var unreadCount: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var isArchived: Bool
    public var isHidden: Bool
    public var disappearingMessagesDuration: Double?
    public var createdAt: Date
    public var updatedAt: Date
    // Denormalized last message
    public var lastMessageId: String?
    public var lastMessageContent: String?
    public var lastMessageTimestamp: Date?
    public var lastMessageSenderId: String?
    public var lastMessageStatus: String?
    /// Unsent composer text. Local to this device and never sent by the
    /// server, so `mergeConversationRecord` keeps the existing value the same
    /// way it keeps `isHidden`.
    public var draftText: String?

    public init(from conversation: Conversation) {
        self.id = conversation.id
        self.type = conversation.type.rawValue
        self.unreadCount = conversation.unreadCount
        self.isPinned = conversation.isPinned
        self.isMuted = conversation.isMuted
        self.isArchived = conversation.isArchived
        self.isHidden = false
        self.disappearingMessagesDuration = conversation.disappearingMessagesDuration
        self.createdAt = conversation.createdAt
        self.updatedAt = conversation.updatedAt
        self.draftText = conversation.draftText

        if let lastMsg = conversation.lastMessage {
            self.lastMessageId = lastMsg.id
            self.lastMessageContent = Self.encodeContent(lastMsg.content)
            self.lastMessageTimestamp = lastMsg.timestamp
            self.lastMessageSenderId = lastMsg.senderId
            self.lastMessageStatus = lastMsg.status.rawValue
        }
    }

    public init(
        id: String,
        type: String,
        unreadCount: Int,
        isPinned: Bool,
        isMuted: Bool,
        isArchived: Bool,
        isHidden: Bool = false,
        disappearingMessagesDuration: Double?,
        createdAt: Date,
        updatedAt: Date,
        lastMessageId: String?,
        lastMessageContent: String?,
        lastMessageTimestamp: Date?,
        lastMessageSenderId: String?,
        lastMessageStatus: String?
    ) {
        self.id = id
        self.type = type
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.disappearingMessagesDuration = disappearingMessagesDuration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageId = lastMessageId
        self.lastMessageContent = lastMessageContent
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessageSenderId = lastMessageSenderId
        self.lastMessageStatus = lastMessageStatus
    }

    public func toDomain(participants: [User]) -> Conversation {
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
            updatedAt: updatedAt,
            draftText: draftText
        )
    }

    private static func encodeContent(_ content: Message.MessageContent) -> String? {
        guard let data = try? JSONEncoder().encode(content) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeContent(_ json: String) -> Message.MessageContent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Message.MessageContent.self, from: data)
    }
}

// MARK: - Conversation Participant Record

public struct ConversationParticipantRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "conversationParticipant"

    public var conversationId: String
    public var userId: String

    public init(conversationId: String, userId: String) {
        self.conversationId = conversationId
        self.userId = userId
    }
}

// MARK: - Message Record

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "message"

    public var id: String
    public var conversationId: String
    public var senderId: String
    public var timestamp: Date
    public var contentJSON: String
    public var status: String
    public var isOutgoing: Bool
    public var replyToMessageId: String?
    public var expiresAt: Date?

    public init(from message: Message) {
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

    public init(
        id: String,
        conversationId: String,
        senderId: String,
        timestamp: Date,
        contentJSON: String,
        status: String,
        isOutgoing: Bool,
        replyToMessageId: String?,
        expiresAt: Date?
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.timestamp = timestamp
        self.contentJSON = contentJSON
        self.status = status
        self.isOutgoing = isOutgoing
        self.replyToMessageId = replyToMessageId
        self.expiresAt = expiresAt
    }

    public func toDomain() -> Message {
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

    public static func encodeContent(_ content: Message.MessageContent) -> String {
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

public struct PendingMessageAckRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "pendingMessageAck"

    public var conversationId: String
    public var messageId: String
    public var createdAt: Date

    public init(from ack: PendingMessageAck) {
        self.conversationId = ack.conversationId
        self.messageId = ack.messageId
        self.createdAt = ack.createdAt
    }

    public func toDomain() -> PendingMessageAck {
        PendingMessageAck(
            conversationId: conversationId,
            messageId: messageId,
            createdAt: createdAt
        )
    }
}

// MARK: - Vault Item Record

public struct VaultItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "vaultItem"

    public var id: String
    public var mediaId: String
    public var name: String
    public var type: String
    public var sizeBytes: Int64
    public var thumbnailData: Data?
    public var encryptedThumbnailURL: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var isCachedLocally: Bool
    public var remoteURL: String?
    public var localURL: String?
    public var status: String

    public init(from item: VaultItem) {
        self.id = item.id
        self.mediaId = item.mediaId
        self.name = item.name
        self.type = item.type.rawValue
        self.sizeBytes = item.sizeBytes
        self.thumbnailData = item.thumbnailData
        self.encryptedThumbnailURL = item.encryptedThumbnailURL?.absoluteString
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.isCachedLocally = item.isCachedLocally
        self.remoteURL = item.remoteURL?.absoluteString
        self.localURL = item.localURL?.absoluteString
        self.status = item.status.rawValue
    }

    public init(
        id: String,
        mediaId: String,
        name: String,
        type: String,
        sizeBytes: Int64,
        thumbnailData: Data?,
        encryptedThumbnailURL: String?,
        createdAt: Date,
        updatedAt: Date,
        isCachedLocally: Bool,
        remoteURL: String?,
        localURL: String?,
        status: String = "live"
    ) {
        self.id = id
        self.mediaId = mediaId
        self.name = name
        self.type = type
        self.sizeBytes = sizeBytes
        self.thumbnailData = thumbnailData
        self.encryptedThumbnailURL = encryptedThumbnailURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isCachedLocally = isCachedLocally
        self.remoteURL = remoteURL
        self.localURL = localURL
        self.status = status
    }

    public func toDomain() -> VaultItem {
        VaultItem(
            id: id,
            mediaId: mediaId,
            name: name,
            type: VaultItem.VaultItemType(rawValue: type) ?? .document,
            sizeBytes: sizeBytes,
            thumbnailData: thumbnailData,
            encryptedThumbnailURL: encryptedThumbnailURL.flatMap { URL(string: $0) },
            createdAt: createdAt,
            updatedAt: updatedAt,
            isCachedLocally: isCachedLocally,
            remoteURL: remoteURL.flatMap { URL(string: $0) },
            localURL: localURL.flatMap { URL(string: $0) },
            status: VaultItem.VaultItemStatus(rawValue: status) ?? .live
        )
    }
}

// MARK: - Chat Appearance Overrides

public struct ChatAppearanceOverrideRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "chatAppearanceOverride"

    public var conversationId: String
    public var wallpaperId: String?
    public var appearanceMode: String?
    public var updatedAt: Date

    public init(
        conversationId: String,
        wallpaperId: String?,
        appearanceMode: String?,
        updatedAt: Date
    ) {
        self.conversationId = conversationId
        self.wallpaperId = wallpaperId
        self.appearanceMode = appearanceMode
        self.updatedAt = updatedAt
    }

    public func toDomain() -> AppearanceOverride {
        AppearanceOverride(
            wallpaperId: wallpaperId,
            appearanceMode: appearanceMode.flatMap(SanchrTheme.Mode.init(rawValue:))
        )
    }

    public static func from(
        conversationId: String,
        override: AppearanceOverride,
        now: Date = Date()
    ) -> ChatAppearanceOverrideRecord {
        ChatAppearanceOverrideRecord(
            conversationId: conversationId,
            wallpaperId: override.wallpaperId,
            appearanceMode: override.appearanceMode?.rawValue,
            updatedAt: now
        )
    }
}

// MARK: - Chat Vault Policy

public struct ChatVaultPolicyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "chatVaultPolicy"

    public var conversationId: String
    public var autoVaultIncoming: Bool
    public var viewOnceOutgoing: Bool
    public var screenshotProtection: Bool
    public var updatedAt: Date

    public init(
        conversationId: String,
        autoVaultIncoming: Bool,
        viewOnceOutgoing: Bool,
        screenshotProtection: Bool,
        updatedAt: Date
    ) {
        self.conversationId = conversationId
        self.autoVaultIncoming = autoVaultIncoming
        self.viewOnceOutgoing = viewOnceOutgoing
        self.screenshotProtection = screenshotProtection
        self.updatedAt = updatedAt
    }

    public func toDomain() -> ChatVaultPolicy {
        ChatVaultPolicy(
            conversationId: conversationId,
            autoVaultIncoming: autoVaultIncoming,
            viewOnceOutgoing: viewOnceOutgoing,
            screenshotProtection: screenshotProtection
        )
    }

    public static func from(_ policy: ChatVaultPolicy, now: Date = Date()) -> ChatVaultPolicyRecord {
        ChatVaultPolicyRecord(
            conversationId: policy.conversationId,
            autoVaultIncoming: policy.autoVaultIncoming,
            viewOnceOutgoing: policy.viewOnceOutgoing,
            screenshotProtection: policy.screenshotProtection,
            updatedAt: now
        )
    }
}
