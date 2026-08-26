import Foundation

public enum BackupArchive {
    public static let formatVersion: Int32 = 1
    public static let automaticBackupInterval: TimeInterval = 6 * 60 * 60
}

public enum BackupArchiveFrameType: String, Codable, Sendable {
    case info
    case contact
    case conversation
    case message
    case vaultItem = "vault_item"
}

public struct BackupArchiveRecordCounts: Codable, Equatable, Sendable {
    public var contacts: Int
    public var conversations: Int
    public var messages: Int
    public var vaultItems: Int

    public init(contacts: Int, conversations: Int, messages: Int, vaultItems: Int) {
        self.contacts = contacts
        self.conversations = conversations
        self.messages = messages
        self.vaultItems = vaultItems
    }
}

public struct BackupArchiveSnapshot: Equatable, Sendable {
    public var info: BackupArchiveInfoFrame
    public var contacts: [BackupArchiveContactFrame]
    public var conversations: [BackupArchiveConversationFrame]
    public var messages: [BackupArchiveMessageFrame]
    public var vaultItems: [BackupArchiveVaultItemFrame]

    public init(
        info: BackupArchiveInfoFrame,
        contacts: [BackupArchiveContactFrame],
        conversations: [BackupArchiveConversationFrame],
        messages: [BackupArchiveMessageFrame],
        vaultItems: [BackupArchiveVaultItemFrame]
    ) {
        self.info = info
        self.contacts = contacts
        self.conversations = conversations
        self.messages = messages
        self.vaultItems = vaultItems
    }

    public var contentCounts: BackupArchiveRecordCounts {
        BackupArchiveRecordCounts(
            contacts: contacts.count,
            conversations: conversations.count,
            messages: messages.count,
            vaultItems: vaultItems.count
        )
    }
}

private struct BackupFrameProbe: Codable {
    let type: BackupArchiveFrameType
}

public struct BackupArchiveInfoFrame: Codable, Equatable, Sendable {
    public var type: BackupArchiveFrameType = .info
    public let formatVersion: Int32
    public let exportedAtMs: Int64
    public let platform: String
    public let appVersion: String
    public let contactCount: Int
    public let conversationCount: Int
    public let messageCount: Int
    public let vaultItemCount: Int

    public init(
        type: BackupArchiveFrameType = .info,
        formatVersion: Int32,
        exportedAtMs: Int64,
        platform: String,
        appVersion: String,
        contactCount: Int,
        conversationCount: Int,
        messageCount: Int,
        vaultItemCount: Int
    ) {
        self.type = type
        self.formatVersion = formatVersion
        self.exportedAtMs = exportedAtMs
        self.platform = platform
        self.appVersion = appVersion
        self.contactCount = contactCount
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.vaultItemCount = vaultItemCount
    }
}

public struct BackupArchiveMediaPayload: Codable, Equatable, Sendable {
    public let url: String
    public let thumbnailURL: String?
    public let encryptionKeyBase64: String?
    public let encryptionIVBase64: String?
    public let mimeType: String?
    public let sizeBytes: Int64?
    public let caption: String?
    public let width: Int?
    public let height: Int?
    public let durationMs: Int64?
    public let fileName: String?

    public init(
        url: String,
        thumbnailURL: String? = nil,
        encryptionKeyBase64: String? = nil,
        encryptionIVBase64: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int64? = nil,
        caption: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int64? = nil,
        fileName: String? = nil
    ) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.encryptionKeyBase64 = encryptionKeyBase64
        self.encryptionIVBase64 = encryptionIVBase64
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.caption = caption
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.fileName = fileName
    }
}

public struct BackupArchiveLocationPayload: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let label: String?

    public init(latitude: Double, longitude: Double, label: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
    }
}

public struct BackupArchiveContactPayload: Codable, Equatable, Sendable {
    public let name: String
    public let phoneNumber: String

    public init(name: String, phoneNumber: String) {
        self.name = name
        self.phoneNumber = phoneNumber
    }
}

public struct BackupArchiveContactFrame: Codable, Equatable, Sendable {
    public var type: BackupArchiveFrameType = .contact
    public let id: String
    public let userId: String?
    public let phoneNumber: String
    public let displayName: String
    public let avatarURL: String?
    public let bio: String?
    public let isVerified: Bool
    public let lastSeenMs: Int64?
    public let status: String
    public let isLocalUser: Bool
    public let isRegistered: Bool
    public let isBlocked: Bool
    public let isFavorite: Bool
    public let lastSyncedAtMs: Int64?

    public init(
        type: BackupArchiveFrameType = .contact,
        id: String,
        userId: String?,
        phoneNumber: String,
        displayName: String,
        avatarURL: String?,
        bio: String?,
        isVerified: Bool,
        lastSeenMs: Int64?,
        status: String,
        isLocalUser: Bool,
        isRegistered: Bool,
        isBlocked: Bool,
        isFavorite: Bool,
        lastSyncedAtMs: Int64?
    ) {
        self.type = type
        self.id = id
        self.userId = userId
        self.phoneNumber = phoneNumber
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.isVerified = isVerified
        self.lastSeenMs = lastSeenMs
        self.status = status
        self.isLocalUser = isLocalUser
        self.isRegistered = isRegistered
        self.isBlocked = isBlocked
        self.isFavorite = isFavorite
        self.lastSyncedAtMs = lastSyncedAtMs
    }
}

public struct BackupArchiveConversationFrame: Codable, Equatable, Sendable {
    public var type: BackupArchiveFrameType = .conversation
    public let id: String
    public let conversationType: String
    public let title: String?
    public let avatarURL: String?
    public let participantIDs: [String]
    public let lastMessageID: String?
    public let lastMessagePreview: String?
    public let lastMessageTimestampMs: Int64?
    public let lastMessageSenderID: String?
    public let lastMessageStatus: String?
    public let lastMessageContentType: String?
    public let lastMessageContentBody: String?
    public let unreadCount: Int
    public let isPinned: Bool
    public let isMuted: Bool
    public let isArchived: Bool
    public let disappearingDurationMs: Int64?
    public let createdAtMs: Int64
    public let updatedAtMs: Int64

    public init(
        type: BackupArchiveFrameType = .conversation,
        id: String,
        conversationType: String,
        title: String?,
        avatarURL: String?,
        participantIDs: [String],
        lastMessageID: String?,
        lastMessagePreview: String?,
        lastMessageTimestampMs: Int64?,
        lastMessageSenderID: String?,
        lastMessageStatus: String?,
        lastMessageContentType: String?,
        lastMessageContentBody: String?,
        unreadCount: Int,
        isPinned: Bool,
        isMuted: Bool,
        isArchived: Bool,
        disappearingDurationMs: Int64?,
        createdAtMs: Int64,
        updatedAtMs: Int64
    ) {
        self.type = type
        self.id = id
        self.conversationType = conversationType
        self.title = title
        self.avatarURL = avatarURL
        self.participantIDs = participantIDs
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestampMs = lastMessageTimestampMs
        self.lastMessageSenderID = lastMessageSenderID
        self.lastMessageStatus = lastMessageStatus
        self.lastMessageContentType = lastMessageContentType
        self.lastMessageContentBody = lastMessageContentBody
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isArchived = isArchived
        self.disappearingDurationMs = disappearingDurationMs
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }
}

public struct BackupArchiveMessageFrame: Codable, Equatable, Sendable {
    public var type: BackupArchiveFrameType = .message
    public let id: String
    public let conversationID: String
    public let senderID: String
    public let timestampMs: Int64
    public let contentType: String
    public let contentBody: String
    public let previewText: String?
    public let status: String
    public let isOutgoing: Bool
    public let replyToMessageID: String?
    public let expiresAtMs: Int64?
    public let isDeleted: Bool

    public init(
        type: BackupArchiveFrameType = .message,
        id: String,
        conversationID: String,
        senderID: String,
        timestampMs: Int64,
        contentType: String,
        contentBody: String,
        previewText: String?,
        status: String,
        isOutgoing: Bool,
        replyToMessageID: String?,
        expiresAtMs: Int64?,
        isDeleted: Bool
    ) {
        self.type = type
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.timestampMs = timestampMs
        self.contentType = contentType
        self.contentBody = contentBody
        self.previewText = previewText
        self.status = status
        self.isOutgoing = isOutgoing
        self.replyToMessageID = replyToMessageID
        self.expiresAtMs = expiresAtMs
        self.isDeleted = isDeleted
    }
}

public struct BackupArchiveVaultItemFrame: Codable, Equatable, Sendable {
    public var type: BackupArchiveFrameType = .vaultItem
    public let id: String                    // vault_item_id (UUIDv4)
    public let mediaId: String                // reference to media_objects
    public let encryptedMetadata: Data        // opaque AES-GCM ciphertext, usually empty (metadata re-fetched from server)
    public let createdAtMs: Int64             // access-key-entry createdAt anchor
    public let lastAccessedAtMs: Int64        // access-key-entry lastAccessedAt anchor
    public let createdOnDevice: String        // SHA256(dls || "sanchr-backup-fingerprint-v1")
    public let kind: String                    // AccessKeyEntry.Kind.rawValue: "messageMedia" | "vaultAutoVaulted" | "vaultManual"

    public init(
        type: BackupArchiveFrameType = .vaultItem,
        id: String,
        mediaId: String,
        encryptedMetadata: Data = Data(),
        createdAtMs: Int64,
        lastAccessedAtMs: Int64,
        createdOnDevice: String,
        kind: String
    ) {
        self.type = type
        self.id = id
        self.mediaId = mediaId
        self.encryptedMetadata = encryptedMetadata
        self.createdAtMs = createdAtMs
        self.lastAccessedAtMs = lastAccessedAtMs
        self.createdOnDevice = createdOnDevice
        self.kind = kind
    }
}

public enum BackupArchiveSerializer {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func serialize(_ snapshot: BackupArchiveSnapshot) throws -> Data {
        var lines: [Data] = []
        lines.append(try encoder.encode(snapshot.info))
        try snapshot.contacts.forEach { lines.append(try encoder.encode($0)) }
        try snapshot.conversations.forEach { lines.append(try encoder.encode($0)) }
        try snapshot.messages.forEach { lines.append(try encoder.encode($0)) }
        try snapshot.vaultItems.forEach { lines.append(try encoder.encode($0)) }

        return lines.reduce(into: Data()) { data, line in
            data.append(line)
            data.append(0x0A)
        }
    }

    public static func deserialize(_ data: Data) throws -> BackupArchiveSnapshot {
        guard let archiveString = String(data: data, encoding: .utf8) else {
            throw AppError.databaseError(reason: "Backup archive is not valid UTF-8 data")
        }

        let lines = archiveString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { Data($0.utf8) }

        var info: BackupArchiveInfoFrame?
        var contacts: [BackupArchiveContactFrame] = []
        var conversations: [BackupArchiveConversationFrame] = []
        var messages: [BackupArchiveMessageFrame] = []
        var vaultItems: [BackupArchiveVaultItemFrame] = []

        for line in lines {
            let probe = try decoder.decode(BackupFrameProbe.self, from: line)
            switch probe.type {
            case .info:
                info = try decoder.decode(BackupArchiveInfoFrame.self, from: line)
            case .contact:
                contacts.append(try decoder.decode(BackupArchiveContactFrame.self, from: line))
            case .conversation:
                conversations.append(try decoder.decode(BackupArchiveConversationFrame.self, from: line))
            case .message:
                messages.append(try decoder.decode(BackupArchiveMessageFrame.self, from: line))
            case .vaultItem:
                vaultItems.append(try decoder.decode(BackupArchiveVaultItemFrame.self, from: line))
            }
        }

        guard let info else {
            throw AppError.databaseError(reason: "Backup archive is missing its info frame")
        }

        return BackupArchiveSnapshot(
            info: info,
            contacts: contacts,
            conversations: conversations,
            messages: messages,
            vaultItems: vaultItems
        )
    }
}

public enum BackupArchiveContentCodec {
    public static func encode(content: Message.MessageContent) throws -> (
        type: String,
        body: String,
        preview: String
    ) {
        switch content {
        case .text(let text):
            return ("text", text, text)
        case .image(let attachment):
            return ("image", try encodeMediaPayload(attachment), attachment.caption ?? "[Image]")
        case .video(let attachment):
            return ("video", try encodeMediaPayload(attachment), attachment.caption ?? "[Video]")
        case .audio(let attachment):
            return ("audio", try encodeMediaPayload(attachment), "[Voice message]")
        case .document(let attachment):
            let fileName = attachment.url.lastPathComponent
            let payload = BackupArchiveMediaPayload(
                url: attachment.url.absoluteString,
                thumbnailURL: attachment.thumbnailURL?.absoluteString,
                encryptionKeyBase64: attachment.encryptionKey.base64EncodedString(),
                encryptionIVBase64: attachment.encryptionIV.base64EncodedString(),
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes,
                caption: attachment.caption,
                width: attachment.width,
                height: attachment.height,
                durationMs: attachment.durationSeconds.map { Int64(($0 * 1000).rounded()) },
                fileName: fileName
            )
            return ("document", try encode(payload), attachment.caption ?? fileName)
        case .location(let latitude, let longitude):
            let payload = BackupArchiveLocationPayload(
                latitude: latitude,
                longitude: longitude,
                label: nil
            )
            return ("location", try encode(payload), "[Location]")
        case .contact(let name, let phoneNumber):
            let payload = BackupArchiveContactPayload(name: name, phoneNumber: phoneNumber)
            return ("contact", try encode(payload), name)
        case .system(let event):
            return ("system", event.rawValue, previewText(for: event))
        }
    }

    public static func decode(type: String, body: String, preview: String?) -> Message.MessageContent {
        switch type {
        case "text":
            return .text(body)
        case "image":
            return decodeMediaAttachment(body).map(Message.MessageContent.image)
                ?? .text(preview ?? "[Image]")
        case "video":
            return decodeMediaAttachment(body).map(Message.MessageContent.video)
                ?? .text(preview ?? "[Video]")
        case "audio", "voice":
            return decodeMediaAttachment(body).map(Message.MessageContent.audio)
                ?? .text(preview ?? "[Voice message]")
        case "document", "file":
            return decodeMediaAttachment(body).map(Message.MessageContent.document)
                ?? .text(preview ?? "[File]")
        case "location":
            if let payload: BackupArchiveLocationPayload = decode(body) {
                return .location(latitude: payload.latitude, longitude: payload.longitude)
            }
            return .text(preview ?? "[Location]")
        case "contact":
            if let payload: BackupArchiveContactPayload = decode(body) {
                return .contact(name: payload.name, phoneNumber: payload.phoneNumber)
            }
            return .text(preview ?? body)
        case "system":
            if let event = Message.SystemEvent(rawValue: body) {
                return .system(event)
            }
            return .text(preview ?? body)
        default:
            return .text(preview ?? body)
        }
    }

    public static func decodeStoredContent(_ json: String) -> (type: String, body: String, preview: String)? {
        guard
            let data = json.data(using: .utf8),
            let content = try? JSONDecoder().decode(Message.MessageContent.self, from: data)
        else {
            return nil
        }
        return try? encode(content: content)
    }

    public static func encodeStoredContent(type: String, body: String, preview: String?) -> String? {
        let content = decode(type: type, body: body, preview: preview)
        guard let data = try? JSONEncoder().encode(content) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeMediaPayload(_ attachment: Message.MediaAttachment) throws -> String {
        let payload = BackupArchiveMediaPayload(
            url: attachment.url.absoluteString,
            thumbnailURL: attachment.thumbnailURL?.absoluteString,
            encryptionKeyBase64: attachment.encryptionKey.base64EncodedString(),
            encryptionIVBase64: attachment.encryptionIV.base64EncodedString(),
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            caption: attachment.caption,
            width: attachment.width,
            height: attachment.height,
            durationMs: attachment.durationSeconds.map { Int64(($0 * 1000).rounded()) },
            fileName: nil
        )
        return try encode(payload)
    }

    private static func decodeMediaAttachment(_ body: String) -> Message.MediaAttachment? {
        guard let payload: BackupArchiveMediaPayload = decode(body),
              let url = URL(string: payload.url)
        else {
            return nil
        }

        return Message.MediaAttachment(
            url: url,
            encryptionKey: Data(base64Encoded: payload.encryptionKeyBase64 ?? "") ?? Data(),
            encryptionIV: Data(base64Encoded: payload.encryptionIVBase64 ?? "") ?? Data(),
            mimeType: payload.mimeType ?? "application/octet-stream",
            sizeBytes: payload.sizeBytes ?? 0,
            thumbnailURL: payload.thumbnailURL.flatMap(URL.init(string:)),
            caption: payload.caption,
            width: payload.width,
            height: payload.height,
            durationSeconds: payload.durationMs.map { Double($0) / 1000.0 }
        )
    }

    private static func previewText(for event: Message.SystemEvent) -> String {
        event.displayLabel
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AppError.encryptionFailed(reason: "Failed to encode backup payload")
        }
        return string
    }

    private static func decode<T: Decodable>(_ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
