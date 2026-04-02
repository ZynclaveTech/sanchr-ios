import Foundation

/// Domain use cases for settings operations.
enum SettingsUseCases {

    /// Updates notification preferences.
    struct UpdateNotificationPreferences: Sendable {
        // TODO: Implement with settings repository
        func execute(enabled: Bool, showPreviews: Bool) async throws {
            // TODO: Persist preferences and update server
        }
    }

    /// Updates privacy settings.
    struct UpdatePrivacySettings: Sendable {
        // TODO: Implement with settings repository
        func execute(readReceipts: Bool, typingIndicators: Bool, lastSeenVisibility: String) async throws {
            // TODO: Persist and sync with server
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
