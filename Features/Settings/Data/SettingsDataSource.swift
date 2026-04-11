import Foundation
import SanchrShared

/// Data source for settings-related gRPC service calls.
/// Translates between domain state and Sanchr_Settings protobuf messages.
final class SettingsDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    private var settingsClient: Sanchr_Settings_SettingsServiceAsyncClientProtocol {
        grpcClient.settingsService
    }

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // MARK: - Get Settings

    /// Fetches the current user settings from the server.
    func getSettings() async throws -> Sanchr_Settings_UserSettings {
        let request = Sanchr_Settings_GetSettingsRequest()

        SanchrLogger.network.info("SettingsDataSource: getSettings")
        return try await settingsClient.getSettings(request)
    }

    // MARK: - Update Settings

    /// Pushes updated settings to the server.
    func updateSettings(settings: Sanchr_Settings_UserSettings) async throws
        -> Sanchr_Settings_UserSettings
    {
        var request = Sanchr_Settings_UpdateSettingsRequest()
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
    ) async throws -> Sanchr_Settings_ProfileResponse {
        var request = Sanchr_Settings_UpdateProfileRequest()
        request.displayName = name
        request.avatarURL = avatarURL
        request.statusText = status

        SanchrLogger.network.info("SettingsDataSource: updateProfile")
        return try await settingsClient.updateProfile(request)
    }

    // MARK: - Toggle Sanchr Mode

    /// Toggles the enhanced privacy mode (Sanchr Mode).
    func toggleSanchrMode(enabled: Bool) async throws -> Sanchr_Settings_UserSettings {
        var request = Sanchr_Settings_ToggleSanchrModeRequest()
        request.enabled = enabled

        SanchrLogger.network.info("SettingsDataSource: toggleSanchrMode enabled=\(enabled)")
        return try await settingsClient.toggleSanchrMode(request)
    }

    // MARK: - Set Registration Lock

    /// Enables or disables registration lock with the supplied PIN.
    /// The PIN is sent over TLS; the backend hashes it before storing.
    func setRegistrationLock(enabled: Bool, pin: String) async throws -> Sanchr_Settings_SetRegistrationLockResponse {
        var request = Sanchr_Settings_SetRegistrationLockRequest()
        request.enabled = enabled
        request.pin = pin

        SanchrLogger.network.info("SettingsDataSource: setRegistrationLock enabled=\(enabled)")
        return try await settingsClient.setRegistrationLock(request)
    }

    // MARK: - Get Storage Usage

    /// Retrieves storage usage breakdown by media type.
    func getStorageUsage() async throws -> Sanchr_Settings_StorageUsageResponse {
        let request = Sanchr_Settings_GetStorageUsageRequest()

        SanchrLogger.network.info("SettingsDataSource: getStorageUsage")
        return try await settingsClient.getStorageUsage(request)
    }
}
