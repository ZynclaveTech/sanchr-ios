import Foundation

// MARK: - vync.settings messages
// Generated from Proto/settings.proto — DO NOT EDIT

struct Vync_Settings_GetSettingsRequest: Codable, Sendable {}

struct Vync_Settings_UserSettings: Codable, Sendable {
    var readReceipts: Bool = false
    var onlineStatusVisible: Bool = false
    var typingIndicator: Bool = false
    var profilePhotoVisibility: String = ""
    var vyncModeEnabled: Bool = false
    var screenLockEnabled: Bool = false
    var screenLockTimeout: Int32 = 0
    var screenshotProtection: Bool = false
    var biometricLock: Bool = false
    var messageNotifications: Bool = false
    var groupNotifications: Bool = false
    var callNotifications: Bool = false
    var notificationSound: String = ""
    var notificationVibrate: Bool = false
    var showPreview: Bool = false
    var theme: String = ""
    var fontSize: String = ""
    var chatWallpaper: String = ""
    var autoDownloadWifi: String = ""
    var autoDownloadMobile: String = ""
    var autoDownloadRoaming: String = ""
    var lowDataMode: Bool = false

    enum CodingKeys: String, CodingKey {
        case readReceipts = "read_receipts"
        case onlineStatusVisible = "online_status_visible"
        case typingIndicator = "typing_indicator"
        case profilePhotoVisibility = "profile_photo_visibility"
        case vyncModeEnabled = "vync_mode_enabled"
        case screenLockEnabled = "screen_lock_enabled"
        case screenLockTimeout = "screen_lock_timeout"
        case screenshotProtection = "screenshot_protection"
        case biometricLock = "biometric_lock"
        case messageNotifications = "message_notifications"
        case groupNotifications = "group_notifications"
        case callNotifications = "call_notifications"
        case notificationSound = "notification_sound"
        case notificationVibrate = "notification_vibrate"
        case showPreview = "show_preview"
        case theme
        case fontSize = "font_size"
        case chatWallpaper = "chat_wallpaper"
        case autoDownloadWifi = "auto_download_wifi"
        case autoDownloadMobile = "auto_download_mobile"
        case autoDownloadRoaming = "auto_download_roaming"
        case lowDataMode = "low_data_mode"
    }
}

struct Vync_Settings_UpdateSettingsRequest: Codable, Sendable {
    var settings: Vync_Settings_UserSettings?
}

struct Vync_Settings_UpdateProfileRequest: Codable, Sendable {
    var displayName: String = ""
    var avatarURL: String = ""
    var statusText: String = ""

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case statusText = "status_text"
    }
}

struct Vync_Settings_ProfileResponse: Codable, Sendable {
    var id: String = ""
    var displayName: String = ""
    var avatarURL: String = ""
    var statusText: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case statusText = "status_text"
    }
}

struct Vync_Settings_ToggleVyncModeRequest: Codable, Sendable {
    var enabled: Bool = false
}

struct Vync_Settings_GetStorageUsageRequest: Codable, Sendable {}

struct Vync_Settings_StorageUsageResponse: Codable, Sendable {
    var photosBytes: Int64 = 0
    var videosBytes: Int64 = 0
    var documentsBytes: Int64 = 0
    var voiceBytes: Int64 = 0
    var otherBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var limitBytes: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case photosBytes = "photos_bytes"
        case videosBytes = "videos_bytes"
        case documentsBytes = "documents_bytes"
        case voiceBytes = "voice_bytes"
        case otherBytes = "other_bytes"
        case totalBytes = "total_bytes"
        case limitBytes = "limit_bytes"
    }
}
