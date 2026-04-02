import Foundation

// MARK: - vync.vault messages
// Generated from Proto/vault.proto — DO NOT EDIT

struct Vync_Vault_GetVaultItemsRequest: Codable, Sendable {
    /// Filter: "all", "photo", "video", "file"
    var filter: String = ""
    var limit: Int32 = 0
    /// Pagination cursor.
    var beforeItemID: String = ""

    enum CodingKeys: String, CodingKey {
        case filter, limit
        case beforeItemID = "before_item_id"
    }
}

struct Vync_Vault_GetVaultItemsResponse: Codable, Sendable {
    var items: [Vync_Vault_VaultItem] = []
    var totalPhotos: Int32 = 0
    var totalVideos: Int32 = 0
    var totalFiles: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case items
        case totalPhotos = "total_photos"
        case totalVideos = "total_videos"
        case totalFiles = "total_files"
    }
}

struct Vync_Vault_CreateVaultItemRequest: Codable, Sendable {
    /// "photo", "video", "file"
    var mediaType: String = ""
    /// S3 URL to encrypted blob.
    var encryptedURL: String = ""
    /// AES key, E2EE encrypted for this user.
    var encryptedKey: Data = Data()
    var thumbnailURL: String = ""
    var fileName: String = ""
    var fileSize: Int64 = 0
    var senderID: String = ""
    /// Expiry duration in seconds.
    var ttlSeconds: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case mediaType = "media_type"
        case encryptedURL = "encrypted_url"
        case encryptedKey = "encrypted_key"
        case thumbnailURL = "thumbnail_url"
        case fileName = "file_name"
        case fileSize = "file_size"
        case senderID = "sender_id"
        case ttlSeconds = "ttl_seconds"
    }
}

struct Vync_Vault_VaultItem: Codable, Sendable, Hashable {
    var itemID: String = ""
    var mediaType: String = ""
    var encryptedURL: String = ""
    var encryptedKey: Data = Data()
    var thumbnailURL: String = ""
    var fileName: String = ""
    var fileSize: Int64 = 0
    var senderID: String = ""
    var expiresAt: Int64 = 0
    var createdAt: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case mediaType = "media_type"
        case encryptedURL = "encrypted_url"
        case encryptedKey = "encrypted_key"
        case thumbnailURL = "thumbnail_url"
        case fileName = "file_name"
        case fileSize = "file_size"
        case senderID = "sender_id"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

struct Vync_Vault_DeleteVaultItemRequest: Codable, Sendable {
    var itemID: String = ""

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
    }
}

struct Vync_Vault_DeleteVaultItemResponse: Codable, Sendable {}

struct Vync_Vault_ShareVaultItemRequest: Codable, Sendable {
    var itemID: String = ""
    var recipientID: String = ""
    /// Item key re-encrypted for recipient's public key (client-provided, required).
    var reEncryptedKey: String = ""

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case recipientID = "recipient_id"
        case reEncryptedKey = "re_encrypted_key"
    }
}

struct Vync_Vault_ShareVaultItemResponse: Codable, Sendable {}
