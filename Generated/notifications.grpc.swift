import Foundation

// MARK: - vync.notifications gRPC Client
// Generated from Proto/notifications.proto — DO NOT EDIT

/// Client protocol for the NotificationService gRPC service.
protocol Vync_Notifications_NotificationServiceClientProtocol: Sendable {
    /// Registers or updates the device push token for APNs/FCM delivery.
    func registerPushToken(_ request: Vync_Notifications_RegisterPushTokenRequest) async throws -> Vync_Notifications_RegisterPushTokenResponse

    /// Updates the user's notification preferences.
    func updateNotificationPrefs(_ request: Vync_Notifications_UpdateNotificationPrefsRequest) async throws -> Vync_Notifications_UpdateNotificationPrefsResponse
}

/// Concrete gRPC client for NotificationService.
final class Vync_Notifications_NotificationServiceClient: Vync_Notifications_NotificationServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func registerPushToken(_ request: Vync_Notifications_RegisterPushTokenRequest) async throws -> Vync_Notifications_RegisterPushTokenResponse {
        SanchrLogger.network.info("gRPC: NotificationService/RegisterPushToken")
        throw AppError.serverUnreachable
    }

    func updateNotificationPrefs(_ request: Vync_Notifications_UpdateNotificationPrefsRequest) async throws -> Vync_Notifications_UpdateNotificationPrefsResponse {
        SanchrLogger.network.info("gRPC: NotificationService/UpdateNotificationPrefs")
        throw AppError.serverUnreachable
    }
}
