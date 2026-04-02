import Foundation

// MARK: - vync.settings gRPC Client
// Generated from Proto/settings.proto — DO NOT EDIT

/// Client protocol for the SettingsService gRPC service.
protocol Vync_Settings_SettingsServiceClientProtocol: Sendable {
    /// Fetches the current user settings.
    func getSettings(_ request: Vync_Settings_GetSettingsRequest) async throws -> Vync_Settings_UserSettings

    /// Updates user settings with the provided values.
    func updateSettings(_ request: Vync_Settings_UpdateSettingsRequest) async throws -> Vync_Settings_UserSettings

    /// Updates the user's profile (display name, avatar, status).
    func updateProfile(_ request: Vync_Settings_UpdateProfileRequest) async throws -> Vync_Settings_ProfileResponse

    /// Toggles Vync Mode (enhanced privacy mode).
    func toggleVyncMode(_ request: Vync_Settings_ToggleVyncModeRequest) async throws -> Vync_Settings_UserSettings

    /// Retrieves storage usage breakdown by media type.
    func getStorageUsage(_ request: Vync_Settings_GetStorageUsageRequest) async throws -> Vync_Settings_StorageUsageResponse
}

/// Concrete gRPC client for SettingsService.
final class Vync_Settings_SettingsServiceClient: Vync_Settings_SettingsServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func getSettings(_ request: Vync_Settings_GetSettingsRequest) async throws -> Vync_Settings_UserSettings {
        SanchrLogger.network.info("gRPC: SettingsService/GetSettings")
        throw AppError.serverUnreachable
    }

    func updateSettings(_ request: Vync_Settings_UpdateSettingsRequest) async throws -> Vync_Settings_UserSettings {
        SanchrLogger.network.info("gRPC: SettingsService/UpdateSettings")
        throw AppError.serverUnreachable
    }

    func updateProfile(_ request: Vync_Settings_UpdateProfileRequest) async throws -> Vync_Settings_ProfileResponse {
        SanchrLogger.network.info("gRPC: SettingsService/UpdateProfile")
        throw AppError.serverUnreachable
    }

    func toggleVyncMode(_ request: Vync_Settings_ToggleVyncModeRequest) async throws -> Vync_Settings_UserSettings {
        SanchrLogger.network.info("gRPC: SettingsService/ToggleVyncMode")
        throw AppError.serverUnreachable
    }

    func getStorageUsage(_ request: Vync_Settings_GetStorageUsageRequest) async throws -> Vync_Settings_StorageUsageResponse {
        SanchrLogger.network.info("gRPC: SettingsService/GetStorageUsage")
        throw AppError.serverUnreachable
    }
}
