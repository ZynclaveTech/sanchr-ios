import Foundation

/// Domain model representing a Sanchr user.
struct User: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var phoneNumber: String
    var displayName: String
    var avatarURL: URL?
    var bio: String?
    var isVerified: Bool
    var lastSeen: Date?
    var identityKeyFingerprint: String?

    /// Online presence status.
    enum Status: String, Codable, Sendable {
        case online
        case offline
        case typing
        case away
    }

    var status: Status

    /// Whether the user is the local (authenticated) user.
    var isLocalUser: Bool = false

    // MARK: - Factory

    static let placeholder = User(
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
