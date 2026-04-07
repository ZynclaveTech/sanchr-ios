import Foundation

enum BackupArchive {
    static let formatVersion: Int32 = 1
    static let automaticBackupInterval: TimeInterval = 6 * 60 * 60
}

enum BackupArchiveFrameType: String, Codable, Sendable {
    case info
    case contact
    case conversation
    case message
    case vaultItem = "vault_item"
}

struct BackupArchiveRecordCounts: Codable, Equatable, Sendable {
    var contacts: Int
    var conversations: Int
    var messages: Int
    var vaultItems: Int
}

struct BackupArchiveSnapshot: Equatable, Sendable {
    var info: BackupArchiveInfoFrame
    var contacts: [BackupArchiveContactFrame]
    var conversations: [BackupArchiveConversationFrame]
    var messages: [BackupArchiveMessageFrame]
    var vaultItems: [BackupArchiveVaultItemFrame]

    var contentCounts: BackupArchiveRecordCounts {
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

struct BackupArchiveInfoFrame: Codable, Equatable, Sendable {
    var type: BackupArchiveFrameType = .info
    let formatVersion: Int32
    let exportedAtMs: Int64
    let platform: String
    let appVersion: String
    let contactCount: Int
    let conversationCount: Int
    let messageCount: Int
    let vaultItemCount: Int
}

struct BackupArchiveMediaPayload: Codable, Equatable, Sendable {
    let url: String
    let thumbnailURL: String?
    let encryptionKeyBase64: String?
    let encryptionIVBase64: String?
    let mimeType: String?
    let sizeBytes: Int64?
    let caption: String?
    let width: Int?
    let height: Int?
    let durationMs: Int64?
    let fileName: String?
}

struct BackupArchiveLocationPayload: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let label: String?
}

struct BackupArchiveContactPayload: Codable, Equatable, Sendable {
    let name: String
    let phoneNumber: String
}

struct BackupArchiveContactFrame: Codable, Equatable, Sendable {
    var type: BackupArchiveFrameType = .contact
    let id: String
    let userId: String?
    let phoneNumber: String
    let displayName: String
    let avatarURL: String?
    let bio: String?
    let isVerified: Bool
    let lastSeenMs: Int64?
    let status: String
    let isLocalUser: Bool
    let isRegistered: Bool
    let isBlocked: Bool
    let isFavorite: Bool
    let lastSyncedAtMs: Int64?
}

struct BackupArchiveConversationFrame: Codable, Equatable, Sendable {
    var type: BackupArchiveFrameType = .conversation
    let id: String
    let conversationType: String
    let title: String?
    let avatarURL: String?
    let participantIDs: [String]
    let lastMessageID: String?
    let lastMessagePreview: String?
    let lastMessageTimestampMs: Int64?
    let lastMessageSenderID: String?
    let lastMessageStatus: String?
    let lastMessageContentType: String?
    let lastMessageContentBody: String?
    let unreadCount: Int
    let isPinned: Bool
    let isMuted: Bool
    let isArchived: Bool
    let disappearingDurationMs: Int64?
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

struct BackupArchiveMessageFrame: Codable, Equatable, Sendable {
    var type: BackupArchiveFrameType = .message
    let id: String
    let conversationID: String
    let senderID: String
    let timestampMs: Int64
    let contentType: String
    let contentBody: String
    let previewText: String?
    let status: String
    let isOutgoing: Bool
    let replyToMessageID: String?
    let expiresAtMs: Int64?
    let isDeleted: Bool
}

struct BackupArchiveVaultItemFrame: Codable, Equatable, Sendable {
    var type: BackupArchiveFrameType = .vaultItem
    let id: String
    let name: String
    let itemType: String
    let sizeBytes: Int64
    let encryptionKeyBase64: String
    let encryptionIVBase64: String
    let encryptedThumbnailURL: String?
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let isCachedLocally: Bool
    let remoteURL: String?
    let localURL: String?
}

enum BackupArchiveSerializer {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func serialize(_ snapshot: BackupArchiveSnapshot) throws -> Data {
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

    static func deserialize(_ data: Data) throws -> BackupArchiveSnapshot {
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

enum BackupArchiveContentCodec {
    static func encode(content: Message.MessageContent) throws -> (
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

    static func decode(type: String, body: String, preview: String?) -> Message.MessageContent {
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

    static func decodeStoredContent(_ json: String) -> (type: String, body: String, preview: String)? {
        guard
            let data = json.data(using: .utf8),
            let content = try? JSONDecoder().decode(Message.MessageContent.self, from: data)
        else {
            return nil
        }
        return try? encode(content: content)
    }

    static func encodeStoredContent(type: String, body: String, preview: String?) -> String? {
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
        switch event {
        case .identityKeyChanged:
            return "Safety number changed"
        case .disappearingTimerChanged:
            return "Disappearing timer updated"
        case .groupCreated:
            return "Group created"
        case .memberAdded:
            return "Member added"
        case .memberRemoved:
            return "Member removed"
        case .screenshotDetected:
            return "Screenshot detected"
        }
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
