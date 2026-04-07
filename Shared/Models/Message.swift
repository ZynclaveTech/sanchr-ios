import Foundation

/// Domain model representing an encrypted message.
struct Message: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let conversationId: String
    let senderId: String
    let timestamp: Date
    var content: MessageContent
    var status: DeliveryStatus
    var isOutgoing: Bool
    var replyToMessageId: String?
    var reactions: [MessageReaction] = []

    /// Disappearing message timer (nil if persistent).
    var expiresAt: Date?

    // MARK: - Content Types

    enum MessageContent: Codable, Hashable, Sendable {
        case text(String)
        case image(MediaAttachment)
        case video(MediaAttachment)
        case audio(MediaAttachment)
        case document(MediaAttachment)
        case location(latitude: Double, longitude: Double)
        case contact(name: String, phoneNumber: String)
        case system(SystemEvent)
    }

    struct MediaAttachment: Codable, Hashable, Sendable {
        let url: URL
        let encryptionKey: Data
        let encryptionIV: Data
        let mimeType: String
        let sizeBytes: Int64
        let thumbnailURL: URL?
        var caption: String?

        /// Width/height for images and videos.
        var width: Int?
        var height: Int?

        /// Duration in seconds for audio and video.
        var durationSeconds: Double?

        /// BlurHash string for instant placeholder display before media download.
        var blurHash: String?

        /// Original filename for documents/files (preserved across the
        /// upload pipeline so the receiver/sender bubble can render
        /// the human-readable name even after the local URL is replaced
        /// with a `sanchr-media://<mediaId>` reference).
        var filename: String?
    }

    enum SystemEvent: String, Codable, Hashable, Sendable {
        case identityKeyChanged
        case disappearingTimerChanged
        case groupCreated
        case memberAdded
        case memberRemoved
        case screenshotDetected
    }

    // MARK: - Delivery Status

    enum DeliveryStatus: String, Codable, Hashable, Sendable {
        case sending
        case sent
        case delivered
        case read
        case failed
    }

    // MARK: - Reactions

    struct MessageReaction: Codable, Hashable, Sendable {
        let emoji: String
        let userId: String
        let timestamp: Date
    }

    // MARK: - Factory

    static func textMessage(
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
