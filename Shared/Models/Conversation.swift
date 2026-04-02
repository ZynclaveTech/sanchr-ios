import Foundation

/// Domain model representing a chat conversation.
struct Conversation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var participants: [User]
    var lastMessage: Message?
    var unreadCount: Int
    var isPinned: Bool
    var isMuted: Bool
    var isArchived: Bool
    var type: ConversationType

    /// Disappearing messages timer setting (seconds). Nil if disabled.
    var disappearingMessagesDuration: TimeInterval?

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Types

    enum ConversationType: String, Codable, Hashable, Sendable {
        case oneToOne
        case group
    }

    // MARK: - Computed

    /// Display name for the conversation (other participant name or group name).
    var displayName: String {
        switch type {
        case .oneToOne:
            return participants.first(where: { !$0.isLocalUser })?.displayName ?? "Unknown"
        case .group:
            // TODO: Store group name separately
            return participants.map(\.displayName).joined(separator: ", ")
        }
    }

    /// Avatar URL (other participant's avatar for 1:1, group avatar for groups).
    var avatarURL: URL? {
        switch type {
        case .oneToOne:
            return participants.first(where: { !$0.isLocalUser })?.avatarURL
        case .group:
            return nil // TODO: Group avatar support
        }
    }

    /// Last activity timestamp for sorting.
    var lastActivityAt: Date {
        lastMessage?.timestamp ?? updatedAt
    }
}
