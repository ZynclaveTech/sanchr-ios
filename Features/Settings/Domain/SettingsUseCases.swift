import Foundation
import SanchrShared

/// Domain use cases for settings operations.
enum SettingsUseCases {

    /// Fetches user settings from the server.
    struct GetSettings: Sendable {
        private let settingsDataSource: SettingsDataSource

        init(settingsDataSource: SettingsDataSource) {
            self.settingsDataSource = settingsDataSource
        }

        func execute() async throws -> Vync_Settings_UserSettings {
            try await settingsDataSource.getSettings()
        }
    }

    /// Updates user settings on the server.
    struct UpdateSettings: Sendable {
        private let settingsDataSource: SettingsDataSource

        init(settingsDataSource: SettingsDataSource) {
            self.settingsDataSource = settingsDataSource
        }

        func execute(settings: Vync_Settings_UserSettings) async throws
            -> Vync_Settings_UserSettings
        {
            try await settingsDataSource.updateSettings(settings: settings)
        }
    }

    /// Updates profile (display name, avatar, status).
    struct UpdateProfile: Sendable {
        private let settingsDataSource: SettingsDataSource

        init(settingsDataSource: SettingsDataSource) {
            self.settingsDataSource = settingsDataSource
        }

        func execute(name: String, avatarURL: String, status: String) async throws
            -> Vync_Settings_ProfileResponse
        {
            try await settingsDataSource.updateProfile(
                name: name, avatarURL: avatarURL, status: status)
        }
    }

    /// Toggles Vync Mode (enhanced privacy).
    struct ToggleVyncMode: Sendable {
        private let settingsDataSource: SettingsDataSource

        init(settingsDataSource: SettingsDataSource) {
            self.settingsDataSource = settingsDataSource
        }

        func execute(enabled: Bool) async throws -> Vync_Settings_UserSettings {
            try await settingsDataSource.toggleVyncMode(enabled: enabled)
        }
    }

    /// Fetches storage usage breakdown.
    struct GetStorageUsage: Sendable {
        private let settingsDataSource: SettingsDataSource

        init(settingsDataSource: SettingsDataSource) {
            self.settingsDataSource = settingsDataSource
        }

        func execute() async throws -> Vync_Settings_StorageUsageResponse {
            try await settingsDataSource.getStorageUsage()
        }
    }

    /// Clears local data and cache.
    struct ClearLocalData: Sendable {
        private let localDatabase: LocalDatabaseProtocol
        private let mediaManager: MediaManagerProtocol

        init(localDatabase: LocalDatabaseProtocol, mediaManager: MediaManagerProtocol) {
            self.localDatabase = localDatabase
            self.mediaManager = mediaManager
        }

        func execute() async throws {
            try await localDatabase.purgeAllData()
            try await mediaManager.clearCache()
        }
    }
}
