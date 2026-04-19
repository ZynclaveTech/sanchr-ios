import Foundation

/// Persisted non-secret session metadata stored alongside tokens in Keychain.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let userId: String
    public let displayName: String
    public let phoneNumber: String
    public let avatarURL: String?
    public let statusText: String?
    public let tokenExpiresAt: Date?
    public let deviceId: String?
    public let installationId: String
    public let lastMessageSyncTimestamp: Int64

    public init(
        userId: String,
        displayName: String,
        phoneNumber: String,
        avatarURL: String? = nil,
        statusText: String? = nil,
        tokenExpiresAt: Date? = nil,
        deviceId: String? = nil,
        installationId: String,
        lastMessageSyncTimestamp: Int64
    ) {
        self.userId = userId
        self.displayName = displayName
        self.phoneNumber = phoneNumber
        self.avatarURL = avatarURL
        self.statusText = statusText
        self.tokenExpiresAt = tokenExpiresAt
        self.deviceId = deviceId
        self.installationId = installationId
        self.lastMessageSyncTimestamp = lastMessageSyncTimestamp
    }
}
