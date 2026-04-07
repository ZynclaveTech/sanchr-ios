import Foundation

/// Domain model representing an encrypted vault item (secure file storage).
public struct VaultItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var type: VaultItemType
    public var sizeBytes: Int64
    public var encryptionKey: Data
    public var encryptionIV: Data
    public var thumbnailData: Data?
    /// URL to the encrypted thumbnail blob in S3 (decrypted with encryptionKey).
    public var encryptedThumbnailURL: URL?
    public var createdAt: Date
    public var updatedAt: Date

    /// Whether the item has been downloaded to the local cache.
    public var isCachedLocally: Bool

    /// Remote storage URL.
    public var remoteURL: URL?

    /// Local file URL (when cached).
    public var localURL: URL?

    public init(
        id: String,
        name: String,
        type: VaultItemType,
        sizeBytes: Int64,
        encryptionKey: Data,
        encryptionIV: Data,
        thumbnailData: Data? = nil,
        encryptedThumbnailURL: URL? = nil,
        createdAt: Date,
        updatedAt: Date,
        isCachedLocally: Bool,
        remoteURL: URL? = nil,
        localURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sizeBytes = sizeBytes
        self.encryptionKey = encryptionKey
        self.encryptionIV = encryptionIV
        self.thumbnailData = thumbnailData
        self.encryptedThumbnailURL = encryptedThumbnailURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isCachedLocally = isCachedLocally
        self.remoteURL = remoteURL
        self.localURL = localURL
    }

    // MARK: - Types

    public enum VaultItemType: String, Codable, Hashable, Sendable {
        case photo
        case video
        case document
        case audio
        case note

        public var systemImage: String {
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
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
