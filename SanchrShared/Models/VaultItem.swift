import Foundation

/// Domain model representing an encrypted vault item (secure file storage).
struct VaultItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var type: VaultItemType
    var sizeBytes: Int64
    var encryptionKey: Data
    var encryptionIV: Data
    var thumbnailData: Data?
    /// URL to the encrypted thumbnail blob in S3 (decrypted with encryptionKey).
    var encryptedThumbnailURL: URL?
    var createdAt: Date
    var updatedAt: Date

    /// Whether the item has been downloaded to the local cache.
    var isCachedLocally: Bool

    /// Remote storage URL.
    var remoteURL: URL?

    /// Local file URL (when cached).
    var localURL: URL?

    // MARK: - Types

    enum VaultItemType: String, Codable, Hashable, Sendable {
        case photo
        case video
        case document
        case audio
        case note

        var systemImage: String {
            switch self {
            case .photo: "photo.fill"
            case .video: "video.fill"
            case .document: "doc.fill"
            case .audio: "waveform"
            case .note: "note.text"
            }
        }
    }

    // MARK: - Computed

    /// Human-readable file size.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
