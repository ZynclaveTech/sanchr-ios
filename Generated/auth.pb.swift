import Foundation

// MARK: - vync.auth messages
// Generated from Proto/auth.proto — DO NOT EDIT

struct Vync_Auth_DeviceInfo: Codable, Sendable, Hashable {
    var deviceName: String = ""
    var platform: String = ""

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case platform
    }
}

struct Vync_Auth_RegisterRequest: Codable, Sendable {
    var phoneNumber: String = ""
    var displayName: String = ""
    var password: String = ""
    var email: String = ""
    var device: Vync_Auth_DeviceInfo?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case displayName = "display_name"
        case password, email, device
    }
}

struct Vync_Auth_VerifyOTPRequest: Codable, Sendable {
    var phoneNumber: String = ""
    var otpCode: String = ""
    var device: Vync_Auth_DeviceInfo?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case otpCode = "otp_code"
        case device
    }
}

struct Vync_Auth_LoginRequest: Codable, Sendable {
    var phoneNumber: String = ""
    var password: String = ""
    var device: Vync_Auth_DeviceInfo?

    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case password, device
    }
}

struct Vync_Auth_RefreshTokenRequest: Codable, Sendable {
    var refreshToken: String = ""

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct Vync_Auth_LogoutRequest: Codable, Sendable {
    var refreshToken: String = ""

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct Vync_Auth_AuthResponse: Codable, Sendable {
    var accessToken: String = ""
    var refreshToken: String = ""
    var user: Vync_Auth_User?
    var deviceID: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
        case deviceID = "device_id"
    }
}

struct Vync_Auth_LogoutResponse: Codable, Sendable {}

struct Vync_Auth_ChangePasswordRequest: Codable, Sendable {
    var currentPassword: String = ""
    var newPassword: String = ""

    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
        case newPassword = "new_password"
    }
}

struct Vync_Auth_ChangePasswordResponse: Codable, Sendable {}

struct Vync_Auth_User: Codable, Sendable, Hashable {
    var id: String = ""
    var phoneNumber: String = ""
    var displayName: String = ""
    var email: String = ""
    var avatarURL: String = ""
    var statusText: String = ""
    var createdAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case phoneNumber = "phone_number"
        case displayName = "display_name"
        case email
        case avatarURL = "avatar_url"
        case statusText = "status_text"
        case createdAt = "created_at"
    }
}
