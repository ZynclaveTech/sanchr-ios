import Foundation

// MARK: - vync.messaging messages
// Generated from Proto/messaging.proto — DO NOT EDIT

struct Vync_Messaging_StartDirectConversationRequest: Codable, Sendable {
    var recipientID: String = ""

    enum CodingKeys: String, CodingKey {
        case recipientID = "recipient_id"
    }
}

struct Vync_Messaging_DeviceMessage: Codable, Sendable {
    var recipientID: String = ""
    var deviceID: Int32 = 0
    var ciphertext: Data = Data()

    enum CodingKeys: String, CodingKey {
        case recipientID = "recipient_id"
        case deviceID = "device_id"
        case ciphertext
    }
}

struct Vync_Messaging_SendMessageRequest: Codable, Sendable {
    var conversationID: String = ""
    var deviceMessages: [Vync_Messaging_DeviceMessage] = []
    var contentType: String = ""
    var expiresAfterSecs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case deviceMessages = "device_messages"
        case contentType = "content_type"
        case expiresAfterSecs = "expires_after_secs"
    }
}

struct Vync_Messaging_SendMessageResponse: Codable, Sendable {
    var messageID: String = ""
    var serverTimestamp: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case serverTimestamp = "server_timestamp"
    }
}

struct Vync_Messaging_ClientEvent: Codable, Sendable {
    var typing: Vync_Messaging_TypingIndicator?
    var receipt: Vync_Messaging_ReceiptRequest?
    var heartbeat: Vync_Messaging_PresenceHeartbeat?

    /// The active oneof case.
    enum OneOf: String, Codable, Sendable {
        case typing
        case receipt
        case heartbeat
    }

    var activeEvent: OneOf? {
        if typing != nil { return .typing }
        if receipt != nil { return .receipt }
        if heartbeat != nil { return .heartbeat }
        return nil
    }
}

struct Vync_Messaging_ServerEvent: Codable, Sendable {
    var message: Vync_Messaging_EncryptedEnvelope?
    var typing: Vync_Messaging_TypingIndicator?
    var receipt: Vync_Messaging_ReceiptUpdate?
    var presence: Vync_Messaging_PresenceUpdate?
    var preKeyCountLow: Vync_Messaging_PreKeyCountLow?

    enum OneOf: String, Codable, Sendable {
        case message
        case typing
        case receipt
        case presence
        case preKeyCountLow = "pre_key_count_low"
    }

    enum CodingKeys: String, CodingKey {
        case message, typing, receipt, presence
        case preKeyCountLow = "pre_key_count_low"
    }

    var activeEvent: OneOf? {
        if message != nil { return .message }
        if typing != nil { return .typing }
        if receipt != nil { return .receipt }
        if presence != nil { return .presence }
        if preKeyCountLow != nil { return .preKeyCountLow }
        return nil
    }
}

struct Vync_Messaging_EncryptedEnvelope: Codable, Sendable {
    var conversationID: String = ""
    var messageID: String = ""
    var senderID: String = ""
    var senderDevice: Int32 = 0
    var ciphertext: Data = Data()
    var contentType: String = ""
    var serverTimestamp: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case senderID = "sender_id"
        case senderDevice = "sender_device"
        case ciphertext
        case contentType = "content_type"
        case serverTimestamp = "server_timestamp"
    }
}

struct Vync_Messaging_TypingIndicator: Codable, Sendable {
    var conversationID: String = ""
    var userID: String = ""
    var isTyping: Bool = false

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case userID = "user_id"
        case isTyping = "is_typing"
    }
}

struct Vync_Messaging_ReceiptRequest: Codable, Sendable {
    var conversationID: String = ""
    var messageID: String = ""
    var status: String = ""

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case status
    }
}

struct Vync_Messaging_ReceiptResponse: Codable, Sendable {}

struct Vync_Messaging_ReceiptUpdate: Codable, Sendable {
    var conversationID: String = ""
    var messageID: String = ""
    var recipientID: String = ""
    var status: String = ""
    var timestamp: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case recipientID = "recipient_id"
        case status, timestamp
    }
}

struct Vync_Messaging_PresenceHeartbeat: Codable, Sendable {}

struct Vync_Messaging_PresenceUpdate: Codable, Sendable {
    var userID: String = ""
    var status: String = ""
    var lastSeen: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case status
        case lastSeen = "last_seen"
    }
}

struct Vync_Messaging_PreKeyCountLow: Codable, Sendable {
    var deviceID: Int32 = 0
    var remainingCount: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case remainingCount = "remaining_count"
    }
}

struct Vync_Messaging_SyncRequest: Codable, Sendable {
    var sinceTimestamp: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case sinceTimestamp = "since_timestamp"
    }
}

struct Vync_Messaging_DeleteMessageRequest: Codable, Sendable {
    var conversationID: String = ""
    var messageID: String = ""

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case messageID = "message_id"
    }
}

struct Vync_Messaging_DeleteMessageResponse: Codable, Sendable {}

struct Vync_Messaging_GetConversationsRequest: Codable, Sendable {}

struct Vync_Messaging_GetConversationsResponse: Codable, Sendable {
    var conversations: [Vync_Messaging_Conversation] = []
}

struct Vync_Messaging_Conversation: Codable, Sendable, Hashable {
    var id: String = ""
    var type: String = ""
    var participantIDs: [String] = []
    var unreadCount: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case id, type
        case participantIDs = "participant_ids"
        case unreadCount = "unread_count"
    }
}
