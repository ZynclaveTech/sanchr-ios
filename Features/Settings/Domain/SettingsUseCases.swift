import Foundation
import SanchrShared

/// Domain use cases for settings operations.
enum SettingsUseCases {

    /// Fetches user settings from the server.
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
