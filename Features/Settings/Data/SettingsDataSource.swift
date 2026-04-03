import Foundation

/// Data source for settings-related gRPC service calls.
/// Translates between domain state and Vync_Settings protobuf messages.
final class SettingsDataSource: @unchecked Sendable {
    private let settingsClient: Vync_Settings_SettingsServiceClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.settingsClient = Vync_Settings_SettingsServiceClient(grpcClient: grpcClient)
    }

    // MARK: - Get Settings

    /// Fetches the current user settings from the server.
    func getSettings() async throws -> Vync_Settings_UserSettings {
        let request = Vync_Settings_GetSettingsRequest()

        SanchrLogger.network.info("SettingsDataSource: getSettings")
        return try await settingsClient.getSettings(request)
    }

    // MARK: - Update Settings

    /// Pushes updated settings to the server.
    func updateSettings(settings: Vync_Settings_UserSettings) async throws
        -> Vync_Settings_UserSettings
    {
        var request = Vync_Settings_UpdateSettingsRequest()
        request.settings = settings

        SanchrLogger.network.info("SettingsDataSource: updateSettings")
        return try await settingsClient.updateSettings(request)
    }

    // MARK: - Update Profile

    /// Updates the user's profile (display name, avatar URL, status text).
    func updateProfile(
        name: String,
        avatarURL: String,
        status: String
    ) async throws -> Vync_Settings_ProfileResponse {
        var request = Vync_Settings_UpdateProfileRequest()
        request.displayName = name
        request.avatarURL = avatarURL
        request.statusText = status

        SanchrLogger.network.info("SettingsDataSource: updateProfile")
        return try await settingsClient.updateProfile(request)
    }

    // MARK: - Toggle Vync Mode

    /// Toggles the enhanced privacy mode (Vync Mode).
    func toggleVyncMode(enabled: Bool) async throws -> Vync_Settings_UserSettings {
        var request = Vync_Settings_ToggleVyncModeRequest()
        request.enabled = enabled

        SanchrLogger.network.info("SettingsDataSource: toggleVyncMode enabled=\(enabled)")
        return try await settingsClient.toggleVyncMode(request)
    }

    // MARK: - Get Storage Usage

    /// Retrieves storage usage breakdown by media type.
    func getStorageUsage() async throws -> Vync_Settings_StorageUsageResponse {
        let request = Vync_Settings_GetStorageUsageRequest()

        SanchrLogger.network.info("SettingsDataSource: getStorageUsage")
        return try await settingsClient.getStorageUsage(request)
    }
}
