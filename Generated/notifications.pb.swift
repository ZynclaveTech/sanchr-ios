import Foundation

// MARK: - vync.notifications messages
// Generated from Proto/notifications.proto — DO NOT EDIT

struct Vync_Notifications_RegisterPushTokenRequest: Codable, Sendable {
    var token: String = ""
    /// "ios" or "android"
    var platform: String = ""
}

struct Vync_Notifications_RegisterPushTokenResponse: Codable, Sendable {}

struct Vync_Notifications_UpdateNotificationPrefsRequest: Codable, Sendable {
    var messageNotifications: Bool = false
    var groupNotifications: Bool = false
    var callNotifications: Bool = false
    var notificationSound: String = ""
    var vibrate: Bool = false
    var showPreview: Bool = false

    enum CodingKeys: String, CodingKey {
        case messageNotifications = "message_notifications"
        case groupNotifications = "group_notifications"
        case callNotifications = "call_notifications"
        case notificationSound = "notification_sound"
        case vibrate
        case showPreview = "show_preview"
    }
}

struct Vync_Notifications_UpdateNotificationPrefsResponse: Codable, Sendable {}
