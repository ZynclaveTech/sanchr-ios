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
        case image(MediaAttachments)
        case video(MediaAttachments)
        case audio(MediaAttachments)
        case document(MediaAttachments)
        case location(latitude: Double, longitude: Double)
        case contact(name: String, phoneNumber: String)
        case system(SystemEvent)

        /// The attachment a media action should operate on.
        public var firstAttachment: MediaAttachment? {
            switch self {
            case .image(let media), .video(let media),
                 .audio(let media), .document(let media):
                return media.first
            case .text, .location, .contact, .system:
                return nil
            }
        }

        /// Whether this carries media the Photos library will accept.
        ///
        /// Documents, voice notes, locations and contacts are all attachments
        /// of a sort, but none of them are something Photos can store —
        /// offering to save them would produce a failure nobody can act on.
        ///
        /// View-once media is excluded on purpose: the whole point is that it
        /// is seen once and gone, and a Save button would be a hole straight
        /// through that.
        public var isSaveableMedia: Bool {
            switch self {
            case .image(let media), .video(let media):
                return media.first?.isViewOnce != true && !media.items.isEmpty
            case .text, .audio, .document, .location, .contact, .system:
                return false
            }
        }
    }

    /// The attachments a media message carries.
    ///
    /// Modelled on Signal, whose `DataMessage` has always had a *repeated*
    /// `attachments` field rather than a distinct album type: one photo is a
    /// list of one, four photos is a list of four, and there is no second code
    /// path for the plural case.
    ///
    /// The enum keeps its synthesized coding, so the payload still sits at the
    /// same place in the JSON; only its shape changed. Decoding accepts both,
    /// which is what lets messages sent before this — and rows already in the
    /// database and in backups — keep working:
    ///
    ///     {"image":{"_0":{...}}}      legacy single object
    ///     {"image":{"_0":[{...}]}}    list
    ///
    /// Encoding always writes the list form.
    public struct MediaAttachments: Codable, Hashable, Sendable {
        public private(set) var items: [MediaAttachment]

        public init(_ items: [MediaAttachment]) {
            self.items = items
        }

        public init(_ single: MediaAttachment) {
            self.items = [single]
        }

        /// The attachment most UI shows when it can only show one. Media
        /// content is never constructed empty, but this stays optional rather
        /// than trapping: a malformed payload from a peer must not crash the
        /// receiver.
        public var first: MediaAttachment? { items.first }

        public var count: Int { items.count }
        public var isEmpty: Bool { items.isEmpty }

        /// The caption for the whole group.
        ///
        /// Signal keeps this on the message body rather than the attachment;
        /// here it lives on the first item, which is the one the bubble renders
        /// the caption beneath. Reading and writing it through this keeps
        /// callers from having to know that.
        public var caption: String? {
            get { items.first?.caption }
            set {
                guard !items.isEmpty else { return }
                items[0].caption = newValue
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([MediaAttachment].self) {
                items = list
            } else {
                // Legacy: a single attachment encoded as an object.
                items = [try container.decode(MediaAttachment.self)]
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(items)
        }
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

        /// The same attachment pointing at a local file.
        ///
        /// A received attachment's `url` is remote; forwarding needs the
        /// decrypted copy on disk while keeping the rest of the metadata —
        /// mime type, filename, voice-note fields — intact.
        public func replacingURL(_ newURL: URL) -> MediaAttachment {
            var copy = MediaAttachment(
                url: newURL,
                encryptionKey: encryptionKey,
                encryptionIV: encryptionIV,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                thumbnailURL: thumbnailURL
            )
            // Everything the initialiser does not take. Set rather than
            // recreated so a field added later is not silently dropped from a
            // forward — it would simply not be carried, which is visible,
            // instead of being carried as a stale default.
            copy.caption = caption
            copy.width = width
            copy.height = height
            copy.durationSeconds = durationSeconds
            copy.blurHash = blurHash
            copy.filename = filename
            copy.isVoiceMessage = isVoiceMessage
            copy.audioDurationMs = audioDurationMs
            copy.audioWaveform = audioWaveform
            copy.isViewOnce = isViewOnce
            return copy
        }

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
        /// The contact's identity key actually changed. Security-relevant: this is
        /// what a server substituting its own key produces. Distinct from
        /// `decryptionFailed`, which is an ordinary delivery problem.
        case identityKeyChanged
        /// A message arrived that could not be decrypted (stale session, corrupt
        /// envelope, skipped-key overflow). Not a security signal on its own.
        case decryptionFailed
        case disappearingTimerChanged
        case groupCreated
        case memberAdded
        case memberRemoved
        case screenshotDetected
        case viewOnceConsumed
        case autoVaulted

        /// Human-readable label. Single source of truth: the transcript, the
        /// conversation list, and the reply banner all render from this, so a new
        /// case cannot reach the UI as a raw enum name.
        public var displayLabel: String {
            switch self {
            case .identityKeyChanged: return "Security code changed"
            case .decryptionFailed: return "Message couldn't be decrypted"
            case .disappearingTimerChanged: return "Disappearing timer changed"
            case .groupCreated: return "Group created"
            case .memberAdded: return "Member added"
            case .memberRemoved: return "Member removed"
            case .screenshotDetected: return "Screenshot detected"
            case .viewOnceConsumed: return "Viewed"
            case .autoVaulted: return "Auto-vaulted media"
            }
        }
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
        isOutgoing: Bool,
        replyToMessageId: String? = nil
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: Date(),
            content: .text(text),
            status: isOutgoing ? .sending : .delivered,
            isOutgoing: isOutgoing,
            replyToMessageId: replyToMessageId
        )
    }
}
