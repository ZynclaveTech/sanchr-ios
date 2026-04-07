import Foundation
import SanchrShared

/// Protocol defining push notification registration and preference operations.
protocol NotificationRepositoryProtocol: AnyObject, Sendable {
    /// Registers the device's push notification token with the server.
    func registerPushToken(_ token: String) async throws

    /// Updates notification preferences on the server.
    func updateNotificationPrefs(
        messageNotifications: Bool,
        groupNotifications: Bool,
        callNotifications: Bool,
        notificationSound: String,
        vibrate: Bool,
        showPreview: Bool
    ) async throws
}

// MARK: - Implementation

final class NotificationRepositoryImpl: NotificationRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func registerPushToken(_ token: String) async throws {
        SanchrLogger.network.info("Registering push token")

        var request = Vync_Notifications_RegisterPushTokenRequest()
        request.token = token
        request.platform = "ios"

        _ = try await grpcClient.notificationService.registerPushToken(request)

        SanchrLogger.network.info("Push token registered successfully")
    }

    func updateNotificationPrefs(
        messageNotifications: Bool,
        groupNotifications: Bool,
        callNotifications: Bool,
        notificationSound: String,
        vibrate: Bool,
        showPreview: Bool
    ) async throws {
        SanchrLogger.network.info("Updating notification preferences")

        var request = Vync_Notifications_UpdateNotificationPrefsRequest()
        request.messageNotifications = messageNotifications
        request.groupNotifications = groupNotifications
        request.callNotifications = callNotifications
        request.notificationSound = notificationSound
        request.vibrate = vibrate
        request.showPreview = showPreview

        _ = try await grpcClient.notificationService.updateNotificationPrefs(request)

        SanchrLogger.network.info("Notification preferences updated")
    }
}
