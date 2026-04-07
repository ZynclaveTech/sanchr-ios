import Foundation

/// Media access key record persisted to the local encrypted store.
public struct AccessKeyEntry: Codable, Sendable {
    public let mediaId: String
    public let accessKey: Data
    public let conversationId: String
    public let createdAt: Date

    public init(mediaId: String, accessKey: Data, conversationId: String, createdAt: Date) {
        self.mediaId = mediaId
        self.accessKey = accessKey
        self.conversationId = conversationId
        self.createdAt = createdAt
    }
}
