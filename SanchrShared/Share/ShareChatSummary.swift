import Foundation

/// Lightweight chat-row projection for surfaces that render a chat picker
/// without hydrating the full `Conversation` aggregate (participants,
/// last message, etc.). Used by the share extension's chat picker to keep
/// its memory footprint small and avoid pulling additional record types
/// into the extension's address space on a cold launch.
public struct ShareChatSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let isGroup: Bool
    public let lastMessagePreview: String?
    public let lastActivityMs: Int64
    public let isPinned: Bool
    public let avatarURL: URL?

    public init(
        id: String,
        title: String,
        isGroup: Bool,
        lastMessagePreview: String?,
        lastActivityMs: Int64,
        isPinned: Bool,
        avatarURL: URL?
    ) {
        self.id = id
        self.title = title
        self.isGroup = isGroup
        self.lastMessagePreview = lastMessagePreview
        self.lastActivityMs = lastActivityMs
        self.isPinned = isPinned
        self.avatarURL = avatarURL
    }
}
