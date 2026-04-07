import Foundation

/// Persisted non-secret session metadata stored alongside tokens in Keychain.
struct SessionSnapshot: Codable, Equatable, Sendable {
    let userId: String
    let displayName: String
    let phoneNumber: String
    let avatarURL: String?
    let tokenExpiresAt: Date?
    let deviceId: String?
    let installationId: String
    let lastMessageSyncTimestamp: Int64
}
