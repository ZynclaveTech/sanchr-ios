import Foundation

/// Domain model representing a Sanchr user.
public struct User: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var phoneNumber: String
    public var displayName: String
    public var avatarURL: URL?
    public var bio: String?
    public var isVerified: Bool
    public var lastSeen: Date?
    public var identityKeyFingerprint: String?

    /// Online presence status.
    public enum Status: String, Codable, Sendable {
        case online
        case offline
        case typing
        case away
    }

    public var status: Status

    /// Whether the user is the local (authenticated) user.
    public var isLocalUser: Bool = false

    public init(
        id: String,
        phoneNumber: String,
        displayName: String,
        avatarURL: URL? = nil,
        bio: String? = nil,
        isVerified: Bool,
        lastSeen: Date? = nil,
        identityKeyFingerprint: String? = nil,
        status: Status,
        isLocalUser: Bool = false
    ) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.isVerified = isVerified
        self.lastSeen = lastSeen
        self.identityKeyFingerprint = identityKeyFingerprint
        self.status = status
        self.isLocalUser = isLocalUser
    }

    // MARK: - Factory

    public static let placeholder = User(
        id: "placeholder",
        phoneNumber: "+1234567890",
        displayName: "Sanchr User",
        avatarURL: nil,
        bio: nil,
        isVerified: false,
        lastSeen: nil,
        identityKeyFingerprint: nil,
        status: .offline
    )
}
