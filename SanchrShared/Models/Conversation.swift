import Foundation

/// Domain model representing a chat conversation.
public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var participants: [User]
    public var lastMessage: Message?
    public var unreadCount: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var isArchived: Bool
    public var type: ConversationType

    /// Disappearing messages timer setting (seconds). Nil if disabled.
    public var disappearingMessagesDuration: TimeInterval?

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Types

    public enum ConversationType: String, Codable, Hashable, Sendable {
        case oneToOne
        case group
    }

    public init(
        id: String,
        participants: [User],
        lastMessage: Message? = nil,
        unreadCount: Int,
        isPinned: Bool,
        isMuted: Bool,
        isArchived: Bool,
        type: ConversationType,
        disappearingMessagesDuration: TimeInterval? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.participants = participants
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isArchived = isArchived
        self.type = type
        self.disappearingMessagesDuration = disappearingMessagesDuration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Computed

    /// Display name for the conversation (other participant name or group name).
    public var displayName: String {
        switch type {
        case .oneToOne:
            return participants.first(where: { !$0.isLocalUser })?.displayName ?? "Unknown"
        case .group:
            // TODO: Store group name separately
            return participants.map(\.displayName).joined(separator: ", ")
        }
    }

    /// Avatar URL (other participant's avatar for 1:1, group avatar for groups).
    public var avatarURL: URL? {
        switch type {
        case .oneToOne:
            return participants.first(where: { !$0.isLocalUser })?.avatarURL
        case .group:
            return nil  // TODO: Group avatar support
        }
    }

    /// Last activity timestamp for sorting.
    public var lastActivityAt: Date {
        lastMessage?.timestamp ?? updatedAt
    }
}
