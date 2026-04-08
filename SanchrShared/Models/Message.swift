import Foundation

/// Domain model representing an encrypted message.
public struct Message: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let conversationId: String
    public let senderId: String
    public let timestamp: Date
    public var content: MessageContent
    public var status: DeliveryStatus
    public var isOutgoing: Bool
    public var replyToMessageId: String?
    public var reactions: [MessageReaction] = []

    /// Disappearing message timer (nil if persistent).
    public var expiresAt: Date?

    public init(
        id: String,
        conversationId: String,
        senderId: String,
        timestamp: Date,
        content: MessageContent,
        status: DeliveryStatus,
        isOutgoing: Bool,
        replyToMessageId: String? = nil,
        reactions: [MessageReaction] = [],
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.timestamp = timestamp
        self.content = content
        self.status = status
        self.isOutgoing = isOutgoing
        self.replyToMessageId = replyToMessageId
        self.reactions = reactions
        self.expiresAt = expiresAt
    }

    // MARK: - Content Types

    public enum MessageContent: Codable, Hashable, Sendable {
        case text(String)
        case image(MediaAttachment)
        case video(MediaAttachment)
        case audio(MediaAttachment)
        case document(MediaAttachment)
        case location(latitude: Double, longitude: Double)
        case contact(name: String, phoneNumber: String)
        case system(SystemEvent)
    }

    public struct MediaAttachment: Codable, Hashable, Sendable {
        public let url: URL
        public let encryptionKey: Data
        public let encryptionIV: Data
        public let mimeType: String
        public let sizeBytes: Int64
        public let thumbnailURL: URL?
        public var caption: String?

        /// Width/height for images and videos.
        public var width: Int?
        public var height: Int?

        /// Duration in seconds for audio and video.
        public var durationSeconds: Double?

        /// BlurHash string for instant placeholder display before media download.
        public var blurHash: String?

        /// Original filename for documents/files (preserved across the
        /// upload pipeline so the receiver/sender bubble can render
        /// the human-readable name even after the local URL is replaced
        /// with a `sanchr-media://<mediaId>` reference).
        public var filename: String?

        /// Voice message metadata. All optional so legacy Codable payloads
        /// without these keys decode to `nil` and continue to work.
        public var isVoiceMessage: Bool?
        public var audioDurationMs: Int?
        public var audioWaveform: [Float]?

        /// View-once flag set by the sender when the per-chat
        /// `viewOnceOutgoing` policy is on. Receiver enforces by
        /// applying ScreenshotProtectionModifier on the gallery and
        /// deleting the local row + cached file on dismiss.
        /// Encoded inside the encrypted envelope — server is blind.
        /// Optional so legacy `Codable` payloads without the key
        /// continue to decode (default nil = standard behavior).
        public var isViewOnce: Bool?

        public init(
            url: URL,
            encryptionKey: Data,
            encryptionIV: Data,
            mimeType: String,
            sizeBytes: Int64,
            thumbnailURL: URL? = nil,
            caption: String? = nil,
            width: Int? = nil,
            height: Int? = nil,
            durationSeconds: Double? = nil,
            blurHash: String? = nil,
            filename: String? = nil,
            isVoiceMessage: Bool? = nil,
            audioDurationMs: Int? = nil,
            audioWaveform: [Float]? = nil,
            isViewOnce: Bool? = nil
        ) {
            self.url = url
            self.encryptionKey = encryptionKey
            self.encryptionIV = encryptionIV
            self.mimeType = mimeType
            self.sizeBytes = sizeBytes
            self.thumbnailURL = thumbnailURL
            self.caption = caption
            self.width = width
            self.height = height
            self.durationSeconds = durationSeconds
            self.blurHash = blurHash
            self.filename = filename
            self.isVoiceMessage = isVoiceMessage
            self.audioDurationMs = audioDurationMs
            self.audioWaveform = audioWaveform
            self.isViewOnce = isViewOnce
        }
    }

    public enum SystemEvent: String, Codable, Hashable, Sendable {
        case identityKeyChanged
        case disappearingTimerChanged
        case groupCreated
        case memberAdded
        case memberRemoved
        case screenshotDetected
        case viewOnceConsumed
        case autoVaulted
    }

    // MARK: - Delivery Status

    public enum DeliveryStatus: String, Codable, Hashable, Sendable {
        case sending
        case sent
        case delivered
        case read
        case failed
    }

    // MARK: - Reactions

    public struct MessageReaction: Codable, Hashable, Sendable {
        public let emoji: String
        public let userId: String
        public let timestamp: Date

        public init(emoji: String, userId: String, timestamp: Date) {
            self.emoji = emoji
            self.userId = userId
            self.timestamp = timestamp
        }
    }

    // MARK: - Factory

    public static func textMessage(
        id: String = UUID().uuidString,
        conversationId: String,
        senderId: String,
        text: String,
        isOutgoing: Bool
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: Date(),
            content: .text(text),
            status: isOutgoing ? .sending : .delivered,
            isOutgoing: isOutgoing
        )
    }
}
