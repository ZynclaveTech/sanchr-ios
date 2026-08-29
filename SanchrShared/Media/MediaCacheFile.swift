import Foundation

/// Filenames for cached media.
///
/// The cache is a plain directory keyed by `<messageId>.<ext>`, so the writer
/// and the reader must derive the same extension from the same mime type. They
/// did not: four separate mappings had grown up across the download manager,
/// the bubble, and two send paths, and they disagreed.
///
/// The disagreements were not theoretical. `image/gif` and `audio/mp4` — both
/// of which the app sends — were in none of the writer's cases, so they were
/// written as `.bin` while every reader looked for `.jpg`. Each GIF and voice
/// note was therefore cached under a name nothing ever read: a guaranteed miss,
/// a re-download on every cold render, and a directory slowly filling with
/// files that could not be found or reclaimed.
///
/// One mapping, used by everyone, is the only way that stays fixed.
public enum MediaCacheFile {

    /// File extension for `mimeType`.
    ///
    /// Unknown types fall back to `bin` deliberately: the value is only ever a
    /// filename suffix, and guessing `jpg` for something that is not a JPEG
    /// would put misleading bytes behind a plausible name. What matters is that
    /// the writer and reader agree, which they now do by construction.
    public static func fileExtension(for mimeType: String) -> String {
        let mime = mimeType.lowercased()
        switch mime {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/aac": return "aac"
        case "audio/m4a", "audio/mp4", "audio/x-m4a": return "m4a"
        case "application/pdf": return "pdf"
        default: break
        }
        // A type the table does not name still has to round-trip, so fall back
        // by family rather than to a single suffix that would collide across
        // unrelated media.
        if mime.hasPrefix("image/") { return "img" }
        if mime.hasPrefix("video/") { return "vid" }
        if mime.hasPrefix("audio/") { return "aud" }
        return "bin"
    }

    /// Cache filename for a message's media.
    public static func fileName(messageId: String, mimeType: String) -> String {
        "\(messageId).\(fileExtension(for: mimeType))"
    }

    /// Cache filename for one tile of a multi-attachment message.
    ///
    /// Tiles share a message id, so the index is what keeps them from
    /// collapsing onto a single cache entry and rendering the same photo.
    public static func fileName(messageId: String, index: Int, mimeType: String) -> String {
        fileName(messageId: "\(messageId)#\(index)", mimeType: mimeType)
    }
}
