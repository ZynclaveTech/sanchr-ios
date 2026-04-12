import Foundation
import UIKit
import UserNotifications
import SanchrShared

// MARK: - Notification Action

/// Represents the user action derived from tapping or interacting with a notification.
enum NotificationAction: Equatable, Sendable {
    case openConversation(conversationId: String)
    case openCall(callId: String)
    case replyToMessage(conversationId: String, text: String)
    case none
}

// MARK: - Notification Categories

/// Identifiers for notification categories and their associated actions.
enum SanchrNotificationCategory {
    static let message = "SANCHR_MESSAGE"
    static let call = "SANCHR_CALL"
    static let missedCall = "SANCHR_MISSED_CALL"

    enum Action {
        static let reply = "SANCHR_REPLY"
        static let markRead = "SANCHR_MARK_READ"
        static let answerCall = "SANCHR_ANSWER_CALL"
        static let declineCall = "SANCHR_DECLINE_CALL"
        static let callBack = "SANCHR_CALL_BACK"
    }
}

// MARK: - Protocol

/// Protocol for push notification management.
protocol PushManagerProtocol: AnyObject, Sendable {
    func requestPermission() async throws -> Bool
    func registerDeviceToken(_ token: Data) async throws
    func handleNotification(userInfo: [AnyHashable: Any]) async
    var isPermissionGranted: Bool { get }
}

// MARK: - PushManager

/// Manages APNs registration, token handling, notification presentation, and user interactions.
@Observable
final class PushManager: NSObject, PushManagerProtocol, @unchecked Sendable {

    // MARK: - State

    /// Whether the user has granted notification authorization.
    private(set) var isPermissionGranted: Bool = false

    /// The hex-encoded APNs device token, nil until registration succeeds.
    private(set) var deviceToken: String?

    /// The most recent notification action, observed by the app router for navigation.
    var pendingAction: NotificationAction = .none

    /// Conversation currently visible in the UI, used to suppress duplicate banners.
    private var activeConversationId: String?

    /// Optional app-provided sync handler used for silent pushes that carry a
    /// structured `SanchrPushPayload` (e.g. non-sealed-sender message pushes).
    var silentPushHandler: (@Sendable (SanchrPushPayload) async -> UIBackgroundFetchResult)?

    /// Called unconditionally on every silent/background push that has **no**
    /// structured payload — i.e. sealed-sender `content-available: 1` wakes.
    /// The handler is responsible for syncing pending messages and scheduling
    /// any local notification to surface new content to the user.
    var onSilentWakeup: (@Sendable () async -> UIBackgroundFetchResult)?

    // MARK: - Dependencies

    private let notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol

    // MARK: - Constants

    /// UserDefaults key for persisting the last uploaded token to avoid redundant uploads.
    private static let lastUploadedTokenKey = "io.sanchr.push.lastUploadedToken"

    /// UserDefaults key for the timestamp of the last successful token rotation.
    private static let lastRotatedAtKey = "io.sanchr.push.lastRotatedAt"

    /// How often (seconds) to rotate the APNs token. 7 days limits the
    /// window in which a static token can be used to track a user.
    private static let rotationIntervalSeconds: TimeInterval = 7 * 24 * 3600

    // MARK: - Init

    init(notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol) {
        self.notificationService = notificationService
        super.init()
    }

    // MARK: - Permission & Registration

    /// Request notification permission from the user and register for remote notifications.
    /// Returns `true` if authorization was granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [
                .alert, .badge, .sound, .providesAppNotificationSettings,
            ])
            isPermissionGranted = granted

            if granted {
                configureCategories()
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                SanchrLogger.push.info("Push notification permission granted")
            } else {
                SanchrLogger.push.info("Push notification permission denied by user")
            }

            return granted
        } catch {
            SanchrLogger.push.error(
                "Failed to request notification permission: \(error.localizedDescription)")
            return false
        }
    }

    /// Conforms to `PushManagerProtocol` -- delegates to `requestAuthorization`.
    func requestPermission() async throws -> Bool {
        return await requestAuthorization()
    }

    /// Called by the AppDelegate when APNs delivers a device token.
    /// Converts the raw token to hex and triggers server upload.
    func didRegisterForRemoteNotifications(deviceToken tokenData: Data) {
        let tokenString = tokenData.map { String(format: "%02.2hhx", $0) }.joined()
        self.deviceToken = tokenString
        SanchrLogger.push.info("APNs device token received: \(tokenString.prefix(8))...")

        // Upload to backend asynchronously
        Task {
            do {
                try await uploadTokenToServer()
            } catch {
                SanchrLogger.push.error("Device token upload failed: \(error.localizedDescription)")
            }
        }
    }

    /// Conforms to `PushManagerProtocol` -- delegates to `didRegisterForRemoteNotifications`.
    func registerDeviceToken(_ token: Data) async throws {
        didRegisterForRemoteNotifications(deviceToken: token)
    }

    /// Requests a fresh APNs token from the OS if the rotation interval has
    /// elapsed. APNs decides whether to issue a new token; calling
    /// `registerForRemoteNotifications()` surfaces any pending rotation.
    /// Call this on each app foreground to enforce the 7-day rotation window.
    @MainActor
    func rotateTokenIfNeeded() {
        let defaults = UserDefaults.standard
        let lastRotated = defaults.object(forKey: Self.lastRotatedAtKey) as? Date
        let elapsed = lastRotated.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed >= Self.rotationIntervalSeconds else { return }
        SanchrLogger.push.info("Push token rotation due — requesting new APNs token")
        UIApplication.shared.registerForRemoteNotifications()
        defaults.set(Date(), forKey: Self.lastRotatedAtKey)
    }

    /// Uploads the current device token to the backend via the NotificationService gRPC endpoint.
    /// Skips the upload if the token has not changed since the last successful upload.
    func uploadTokenToServer() async throws {
        guard let token = deviceToken else {
            SanchrLogger.push.warning("No device token available for upload")
            return
        }

        // Deduplicate: skip if token hasn't changed
        let lastUploaded = UserDefaults.standard.string(forKey: Self.lastUploadedTokenKey)
        if lastUploaded == token {
            SanchrLogger.push.info("Device token unchanged, skipping upload")
            return
        }

        var request = Sanchr_Notifications_RegisterPushTokenRequest()
        request.token = token
        request.platform = "ios"

        _ = try await notificationService.registerPushToken(request)

        // Persist on success to avoid redundant uploads
        UserDefaults.standard.set(token, forKey: Self.lastUploadedTokenKey)
        SanchrLogger.push.info("Device token uploaded to server successfully")
    }

    // MARK: - Notification Categories & Actions

    /// Configure interactive notification categories:
    /// - Message: inline reply + mark as read
    /// - Call: answer + decline
    /// - Missed call: call back
    func configureCategories() {
        // Message category
        let replyAction = UNTextInputNotificationAction(
            identifier: SanchrNotificationCategory.Action.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a message..."
        )
        let markReadAction = UNNotificationAction(
            identifier: SanchrNotificationCategory.Action.markRead,
            title: "Mark as Read",
            options: []
        )
        let messageCategory = UNNotificationCategory(
            identifier: SanchrNotificationCategory.message,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New encrypted message",
            options: .customDismissAction
        )

        // Incoming call category
        let answerAction = UNNotificationAction(
            identifier: SanchrNotificationCategory.Action.answerCall,
            title: "Answer",
            options: [.foreground]
        )
        let declineAction = UNNotificationAction(
            identifier: SanchrNotificationCategory.Action.declineCall,
            title: "Decline",
            options: [.destructive]
        )
        let callCategory = UNNotificationCategory(
            identifier: SanchrNotificationCategory.call,
            actions: [answerAction, declineAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Incoming call",
            options: []
        )

        // Missed call category
        let callBackAction = UNNotificationAction(
            identifier: SanchrNotificationCategory.Action.callBack,
            title: "Call Back",
            options: [.foreground]
        )
        let missedCallCategory = UNNotificationCategory(
            identifier: SanchrNotificationCategory.missedCall,
            actions: [callBackAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Missed call",
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            messageCategory,
            callCategory,
            missedCallCategory,
        ])

        SanchrLogger.push.info("Notification categories configured")
    }

    // MARK: - Notification Handling

    /// Handle a foreground notification. Returns presentation options.
    /// Shows banner for notifications not belonging to the currently active conversation.
    func handleForegroundNotification(_ notification: UNNotification)
        -> UNNotificationPresentationOptions
    {
        let userInfo = notification.request.content.userInfo
        guard let payload = SanchrPushPayload.from(userInfo: userInfo) else {
            // Unknown payload -- show it anyway
            return [.banner, .sound, .badge]
        }

        // Suppress notification if the user is already viewing this conversation.
        // The active conversation ID would be set by ChatDetailView on appear.
        if let conversationId = payload.conversationId,
            conversationId == activeConversationId
        {
            SanchrLogger.push.info(
                "Suppressing notification for active conversation \(conversationId.prefix(8))...")
            return []
        }

        switch payload.type {
        case .message:
            return [.banner, .sound, .badge, .list]
        case .call:
            // Calls are typically handled via CallKit; show banner as fallback
            return [.banner, .sound]
        case .missedCall:
            return [.banner, .sound, .badge, .list]
        case .system:
            return [.banner, .list]
        }
    }

    /// Handle the user's response to a notification (tap, reply, action button).
    func handleNotificationResponse(_ response: UNNotificationResponse) -> NotificationAction {
        let userInfo = response.notification.request.content.userInfo
        let payload = SanchrPushPayload.from(userInfo: userInfo)
        let actionIdentifier = response.actionIdentifier

        switch actionIdentifier {
        // Inline reply from notification
        case SanchrNotificationCategory.Action.reply:
            if let textResponse = response as? UNTextInputNotificationResponse,
                let conversationId = payload?.conversationId
            {
                SanchrLogger.push.info(
                    "Reply action for conversation \(conversationId.prefix(8))...")
                return .replyToMessage(conversationId: conversationId, text: textResponse.userText)
            }
            return .none

        // Mark as read -- no navigation needed, handled silently
        case SanchrNotificationCategory.Action.markRead:
            SanchrLogger.push.info("Mark as read action")
            return .none

        // Answer call
        case SanchrNotificationCategory.Action.answerCall:
            if let callId = payload?.callId {
                SanchrLogger.push.info("Answer call action: \(callId.prefix(8))...")
                return .openCall(callId: callId)
            }
            return .none

        // Decline call -- no navigation
        case SanchrNotificationCategory.Action.declineCall:
            SanchrLogger.push.info("Decline call action")
            return .none

        // Call back from missed call
        case SanchrNotificationCategory.Action.callBack:
            if let callId = payload?.callId {
                return .openCall(callId: callId)
            }
            return .none

        // Default tap on notification
        case UNNotificationDefaultActionIdentifier:
            return defaultActionForPayload(payload)

        // Dismiss
        case UNNotificationDismissActionIdentifier:
            return .none

        default:
            return defaultActionForPayload(payload)
        }
    }

    /// Conforms to `PushManagerProtocol`.
    func handleNotification(userInfo: [AnyHashable: Any]) async {
        guard let payload = SanchrNotificationService.processPayload(userInfo) else { return }

        switch payload.type {
        case .message:
            if let conversationId = payload.conversationId {
                pendingAction = .openConversation(conversationId: conversationId)
            }
        case .call:
            if let callId = payload.callId {
                pendingAction = .openCall(callId: callId)
            }
        case .missedCall:
            if let callId = payload.callId {
                pendingAction = .openCall(callId: callId)
            }
        case .system:
            break
        }
    }

    /// Handle silent push for background data sync.
    /// Returns the appropriate `UIBackgroundFetchResult`.
    func handleSilentPush(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let payload = SanchrNotificationService.processPayload(userInfo)

        if let payload {
            SanchrLogger.push.info("Handling silent push: type=\(payload.type.rawValue)")

            // Update badge if provided.
            if let badge = payload.badge {
                await SanchrNotificationService.updateBadgeCount(badge)
            }

            if let silentPushHandler {
                return await silentPushHandler(payload)
            }

            return payload.badge == nil ? .noData : .newData
        }

        // No structured payload — this is a sealed-sender `content-available`
        // wake with zero custom data. Hand off to the unconditional sync
        // handler so pending messages are fetched and a local notification
        // is scheduled for the user.
        SanchrLogger.push.info("Silent push: no structured payload, triggering background sync")
        if let onSilentWakeup {
            return await onSilentWakeup()
        }

        return .noData
    }

    // MARK: - Active Conversation Tracking

    func setActiveConversation(_ conversationId: String?) {
        activeConversationId = conversationId
    }

    func resetUploadState() {
        UserDefaults.standard.removeObject(forKey: Self.lastUploadedTokenKey)
        deviceToken = nil
        pendingAction = .none
        activeConversationId = nil
    }

    // MARK: - Private Helpers

    private func defaultActionForPayload(_ payload: SanchrPushPayload?) -> NotificationAction {
        guard let payload else { return .none }

        switch payload.type {
        case .message:
            if let conversationId = payload.conversationId {
                return .openConversation(conversationId: conversationId)
            }
        case .call, .missedCall:
            if let callId = payload.callId {
                return .openCall(callId: callId)
            }
        case .system:
            break
        }

        return .none
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushManager: UNUserNotificationCenterDelegate {

    /// Called when a notification is delivered while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return handleForegroundNotification(notification)
    }

    /// Called when the user interacts with a notification (tap, action button, inline reply).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = handleNotificationResponse(response)
        pendingAction = action

        SanchrLogger.push.info("Notification response handled: \(String(describing: action))")
    }
}

// MARK: - Notification Content Builders

extension PushManager {

    /// Create a local notification for an incoming message (e.g., received via gRPC stream while backgrounded).
    static func createMessageNotification(
        senderName: String,
        messagePreview: String,
        conversationId: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = messagePreview
        content.sound = .default
        content.threadIdentifier = conversationId
        content.categoryIdentifier = SanchrNotificationCategory.message
        content.userInfo = [
            "sanchr": [
                "type": "message",
                "conversation_id": conversationId,
                "sender_name": senderName,
                "message_preview": messagePreview,
            ]
        ]
        return content
    }

    /// Create a local notification for an incoming call.
    static func createCallNotification(
        callerName: String,
        callType: String,
        callId: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Incoming \(callType) call"
        content.body = callerName
        content.sound = UNNotificationSound(named: UNNotificationSoundName("ringtone.caf"))
        content.categoryIdentifier = SanchrNotificationCategory.call
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            "sanchr": [
                "type": "call",
                "call_id": callId,
                "call_type": callType,
                "sender_name": callerName,
            ]
        ]
        return content
    }

    /// Create a notification for a missed call.
    static func createMissedCallNotification(
        callerName: String,
        callType: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Missed \(callType) call"
        content.body = callerName
        content.sound = .default
        content.categoryIdentifier = SanchrNotificationCategory.missedCall
        content.userInfo = [
            "sanchr": [
                "type": "missed_call",
                "sender_name": callerName,
                "call_type": callType,
            ]
        ]
        return content
    }
}
