import Foundation

/// Resolved appearance for a chat — the merge result of global
/// settings and any per-chat override row. Both fields are non-nil:
/// the resolver fills in defaults from global state when an override
/// is missing.
public struct ChatAppearance: Equatable, Sendable {
    public let wallpaperId: String
    public let appearanceMode: SanchrTheme.Mode
    public let isPerChatOverride: Bool

    public init(
        wallpaperId: String,
        appearanceMode: SanchrTheme.Mode,
        isPerChatOverride: Bool
    ) {
        self.wallpaperId = wallpaperId
        self.appearanceMode = appearanceMode
        self.isPerChatOverride = isPerChatOverride
    }
}

/// Optional pair persisted in the chatAppearanceOverride table.
/// Either field may be nil; nil means "fall back to global". An
/// override with both fields nil is meaningless and `setOverride`
/// short-circuits to a delete instead of writing the row.
public struct AppearanceOverride: Equatable, Sendable {
    public let wallpaperId: String?
    public let appearanceMode: SanchrTheme.Mode?

    public init(wallpaperId: String?, appearanceMode: SanchrTheme.Mode?) {
        self.wallpaperId = wallpaperId
        self.appearanceMode = appearanceMode
    }
}
