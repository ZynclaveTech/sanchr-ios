import Foundation

// MARK: - vync.media messages
// Generated from Proto/media.proto — DO NOT EDIT

struct Vync_Media_GetUploadUrlRequest: Codable, Sendable {
    var fileSize: Int64 = 0
    /// MIME type: "image/jpeg", "video/mp4", etc.
    var contentType: String = ""
    /// Hash of encrypted blob for dedup.
    var sha256Hash: String = ""

    enum CodingKeys: String, CodingKey {
        case fileSize = "file_size"
        case contentType = "content_type"
        case sha256Hash = "sha256_hash"
    }
}

struct Vync_Media_GetDownloadUrlRequest: Codable, Sendable {
    var mediaID: String = ""

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
    }
}

struct Vync_Media_PresignedUrlResponse: Codable, Sendable {
    var url: String = ""
    var mediaID: String = ""
    /// Seconds until URL expires.
    var expiresIn: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case url
        case mediaID = "media_id"
        case expiresIn = "expires_in"
    }
}

struct Vync_Media_ConfirmUploadRequest: Codable, Sendable {
    var mediaID: String = ""
    var fileSize: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case fileSize = "file_size"
    }
}

struct Vync_Media_ConfirmUploadResponse: Codable, Sendable {
    var mediaID: String = ""

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
    }
}
