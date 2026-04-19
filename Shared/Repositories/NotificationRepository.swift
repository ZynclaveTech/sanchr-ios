import Foundation
import GRPC
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

    /// Updates this device's notification preference for one conversation.
    func setConversationNotificationPrefs(conversationId: String, muted: Bool) async throws
}

// MARK: - Implementation

final class NotificationRepositoryImpl: NotificationRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func registerPushToken(_ token: String) async throws {
        SanchrLogger.network.info("Registering push token")

        var request = Sanchr_Notifications_RegisterPushTokenRequest()
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

        var request = Sanchr_Notifications_UpdateNotificationPrefsRequest()
        request.messageNotifications = messageNotifications
        request.groupNotifications = groupNotifications
        request.callNotifications = callNotifications
        request.notificationSound = notificationSound
        request.vibrate = vibrate
        request.showPreview = showPreview

        _ = try await grpcClient.notificationService.updateNotificationPrefs(request)

        SanchrLogger.network.info("Notification preferences updated")
    }

    func setConversationNotificationPrefs(conversationId: String, muted: Bool) async throws {
        SanchrLogger.network.info(
            "Updating conversation notification preferences for \(conversationId.prefix(8))...")

        var request = Sanchr_Notifications_SetConversationNotificationPrefsRequest()
        request.conversationID = conversationId
        request.muted = muted

        _ = try await grpcClient.notificationService.setConversationNotificationPrefs(request)

        SanchrLogger.network.info("Conversation notification preferences updated")
    }
}

extension Sanchr_Notifications_NotificationServiceAsyncClientProtocol {
    func setConversationNotificationPrefs(
        _ request: Sanchr_Notifications_SetConversationNotificationPrefsRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Notifications_SetConversationNotificationPrefsResponse {
        try await performAsyncUnaryCall(
            path: "/sanchr.notifications.NotificationService/SetConversationNotificationPrefs",
            request: request,
            callOptions: callOptions ?? defaultCallOptions,
            interceptors: interceptors?.makeSetConversationNotificationPrefsInterceptors() ?? []
        )
    }
}
