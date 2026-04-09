import Foundation

/// A vault item in its forward-secure form.
///
/// Key material is NOT stored on this struct. The decrypt path fetches the
/// AccessK_vault from `AccessKeyStore` keyed by `id` at access time. This
/// struct carries only the public identity of the item and the metadata
/// that the UI needs to render it locally.
public struct VaultItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var mediaId: String
    public var name: String
    public var type: VaultItemType
    public var sizeBytes: Int64
    public var thumbnailData: Data?
    public var encryptedThumbnailURL: URL?
    public var createdAt: Date
    public var updatedAt: Date
    public var isCachedLocally: Bool
    public var remoteURL: URL?
    public var localURL: URL?
    public var status: VaultItemStatus

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

    public enum VaultItemStatus: String, Codable, Hashable, Sendable {
        /// Fully accessible on this device: AccessK_vault is derivable via
        /// the local dls.
        case live
        /// Item was restored from a backup created on a different device.
        /// The metadata is preserved but `AccessK_vault` cannot be derived
        /// here. The vault UI hides sealed items.
        case sealed
    }

    public init(
        id: String,
        mediaId: String,
        name: String,
        type: VaultItemType,
        sizeBytes: Int64,
        thumbnailData: Data? = nil,
        encryptedThumbnailURL: URL? = nil,
        createdAt: Date,
        updatedAt: Date,
        isCachedLocally: Bool = false,
        remoteURL: URL? = nil,
        localURL: URL? = nil,
        status: VaultItemStatus = .live
    ) {
        self.id = id
        self.mediaId = mediaId
        self.name = name
        self.type = type
        self.sizeBytes = sizeBytes
        self.thumbnailData = thumbnailData
        self.encryptedThumbnailURL = encryptedThumbnailURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isCachedLocally = isCachedLocally
        self.remoteURL = remoteURL
        self.localURL = localURL
        self.status = status
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
