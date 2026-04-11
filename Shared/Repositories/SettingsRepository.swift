import Foundation
import SanchrShared

/// Protocol defining user settings and profile operations.
protocol SettingsRepositoryProtocol: AnyObject, Sendable {
    /// Fetches the current user's settings from the server.
    func getSettings() async throws -> Sanchr_Settings_UserSettings

    /// Updates the user's settings on the server.
    func updateSettings(_ settings: Sanchr_Settings_UserSettings) async throws -> Sanchr_Settings_UserSettings

    /// Updates the user's profile (display name, avatar, status).
    func updateProfile(displayName: String, avatarURL: String, statusText: String) async throws -> Sanchr_Settings_ProfileResponse

    /// Toggles Sanchr Mode (enhanced privacy mode) on or off.
    func toggleSanchrMode(enabled: Bool) async throws -> Sanchr_Settings_UserSettings

    /// Fetches storage usage breakdown from the server.
    func getStorageUsage() async throws -> Sanchr_Settings_StorageUsageResponse
}

// MARK: - Implementation

final class SettingsRepositoryImpl: SettingsRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func getSettings() async throws -> Sanchr_Settings_UserSettings {
        SanchrLogger.network.info("Fetching user settings")

        let request = Sanchr_Settings_GetSettingsRequest()
        return try await grpcClient.settingsService.getSettings(request)
    }

    func updateSettings(_ settings: Sanchr_Settings_UserSettings) async throws -> Sanchr_Settings_UserSettings {
        SanchrLogger.network.info("Updating user settings")

        var request = Sanchr_Settings_UpdateSettingsRequest()
        request.settings = settings

        return try await grpcClient.settingsService.updateSettings(request)
    }

    func updateProfile(displayName: String, avatarURL: String, statusText: String) async throws -> Sanchr_Settings_ProfileResponse {
        SanchrLogger.network.info("Updating user profile")

        var request = Sanchr_Settings_UpdateProfileRequest()
        request.displayName = displayName
        request.avatarURL = avatarURL
        request.statusText = statusText

        return try await grpcClient.settingsService.updateProfile(request)
    }

    func toggleSanchrMode(enabled: Bool) async throws -> Sanchr_Settings_UserSettings {
        SanchrLogger.network.info("Toggling Sanchr Mode: \(enabled)")

        var request = Sanchr_Settings_ToggleSanchrModeRequest()
        request.enabled = enabled

        return try await grpcClient.settingsService.toggleSanchrMode(request)
    }

    func getStorageUsage() async throws -> Sanchr_Settings_StorageUsageResponse {
        SanchrLogger.network.info("Fetching storage usage")

        let request = Sanchr_Settings_GetStorageUsageRequest()
        return try await grpcClient.settingsService.getStorageUsage(request)
    }
}
