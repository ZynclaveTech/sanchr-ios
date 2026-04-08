import Foundation
import SanchrShared

/// Single source of truth for the global ↔ per-chat wallpaper + theme
/// merge. View code reads `effectiveAppearance(for:)` and writes through
/// `setOverride` (per-chat) or `setGlobal` (Settings → Appearance).
///
/// `@Observable` so any view that calls `effectiveAppearance(for:)`
/// redraws automatically when either the override cache or the global
/// slot mutates. The override cache is hydrated on demand via
/// `loadOverride(conversationId:)` which `ChatDetailView.task` calls
/// before first paint to avoid a flash from global → override.
@Observable
@MainActor
final class ChatAppearanceService {
    var globalWallpaperId: String
    var globalMode: SanchrTheme.Mode

    /// Bumped on every override / global write so consumers (notably
    /// `ChatDetailView`) can read it inside their `body` to register an
    /// unambiguous observation. @Observable propagation through method
    /// calls + private dictionaries is fragile across NavigationStack
    /// pop boundaries; this counter makes the dependency explicit.
    var changeVersion: UInt64 = 0

    private var overrides: [String: AppearanceOverride] = [:]
    private var loadedConversationIds: Set<String> = []

    private let localDatabase: LocalDatabaseProtocol
    private let theme: SanchrTheme
    private let settingsViewModel: SettingsViewModel

    init(
        localDatabase: LocalDatabaseProtocol,
        theme: SanchrTheme,
        settingsViewModel: SettingsViewModel
    ) {
        self.localDatabase = localDatabase
        self.theme = theme
        self.settingsViewModel = settingsViewModel
        self.globalWallpaperId = settingsViewModel.chatWallpaper.isEmpty
            ? "default"
            : settingsViewModel.chatWallpaper
        self.globalMode = theme.mode
    }

    /// Resolution: per-chat override fields beat global; nil falls back.
    func effectiveAppearance(for conversationId: String) -> ChatAppearance {
        let override = overrides[conversationId]
        return ChatAppearance(
            wallpaperId: override?.wallpaperId ?? globalWallpaperId,
            appearanceMode: override?.appearanceMode ?? globalMode,
            isPerChatOverride: override != nil
        )
    }

    /// Hydrate the override cache from the local database. Idempotent —
    /// the second call for the same conversationId is a no-op so external
    /// DB mutations don't sneak in mid-session.
    func loadOverride(conversationId: String) async {
        guard !loadedConversationIds.contains(conversationId) else { return }
        loadedConversationIds.insert(conversationId)
        if let row = try? await localDatabase.fetchAppearanceOverride(conversationId: conversationId) {
            overrides[conversationId] = row
        }
    }

    /// Per-chat write. nil + nil clears the row entirely.
    func setOverride(
        conversationId: String,
        wallpaperId: String?,
        appearanceMode: SanchrTheme.Mode?
    ) async {
        if wallpaperId == nil && appearanceMode == nil {
            try? await localDatabase.clearAppearanceOverride(conversationId: conversationId)
            overrides.removeValue(forKey: conversationId)
            loadedConversationIds.insert(conversationId)
            changeVersion &+= 1
            return
        }
        let override = AppearanceOverride(
            wallpaperId: wallpaperId,
            appearanceMode: appearanceMode
        )
        try? await localDatabase.setAppearanceOverride(override, for: conversationId)
        overrides[conversationId] = override
        loadedConversationIds.insert(conversationId)
        changeVersion &+= 1
    }

    /// Global write. Mirrors to SettingsViewModel + SanchrTheme so the
    /// existing backend sync paths keep working unchanged.
    func setGlobal(
        wallpaperId: String?,
        appearanceMode: SanchrTheme.Mode?
    ) {
        if let wallpaperId {
            globalWallpaperId = wallpaperId
            settingsViewModel.chatWallpaper = wallpaperId
        }
        if let appearanceMode {
            globalMode = appearanceMode
            theme.mode = appearanceMode
        }
        changeVersion &+= 1
    }
}
