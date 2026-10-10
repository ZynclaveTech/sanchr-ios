import CryptoKit
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
        fileName(messageId: messageId, ext: fileExtension(for: mimeType))
    }

    /// Cache filename for a message's media, for a caller that already holds
    /// the extension.
    public static func fileName(messageId: String, ext: String) -> String {
        "\(safeId(messageId)).\(ext)"
    }

    // MARK: - Ids as path components

    /// `messageId` as something that is safe to use as one path component.
    ///
    /// The id comes out of the message, and the message comes from someone
    /// else: a sealed payload may carry any string as its `message_id`. Used
    /// as a filename as it stood, `../../Library/x` named a file outside the
    /// cache directory, which the download path then wrote decrypted bytes to.
    ///
    /// An id of the shape both apps actually produce is returned unchanged, so
    /// files cached before this existed are still found and still removed.
    /// Anything else is replaced by its hash: still a stable name for that
    /// message, and one with no separators in it. A trailing `#<n>` — an album
    /// tile — is kept apart from the hashing so that a message's tiles still
    /// share its prefix, which is how they are found when it is deleted.
    public static func safeId(_ messageId: String) -> String {
        var base = Substring(messageId)
        var tile = ""
        if let hash = messageId.lastIndex(of: "#") {
            let suffix = messageId[messageId.index(after: hash)...]
            if !suffix.isEmpty, suffix.count <= 4, suffix.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                base = messageId[..<hash]
                tile = "#" + suffix
            }
        }
        let safeBase = isWellFormedId(String(base)) ? String(base) : sha256Hex(String(base))
        return safeBase + tile
    }

    /// Whether `id` is a shape a message id is allowed to have: ASCII letters,
    /// digits, `-` and `_`, and not unreasonably long.
    public static func isWellFormedId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 96 else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// A sender's filename as something safe to use as one path component, or
    /// nil when nothing usable is left.
    ///
    /// The filename travels in the message. It is shown to the user and, for
    /// documents, becomes the name of a link on disk so that QuickLook and the
    /// share sheet say "report.pdf" rather than a message id. `../../x` there
    /// placed that link — to decrypted bytes — wherever the sender liked
    /// inside the app's container.
    public static func safeDisplayName(_ filename: String?) -> String? {
        guard let filename else { return nil }
        // Both separators: a name built on Windows is still a path here once
        // something splits on the other one.
        let last = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return String(cleaned.prefix(255))
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Cache filename for one tile of a multi-attachment message.
    ///
    /// Tiles share a message id, so the index is what keeps them from
    /// collapsing onto a single cache entry and rendering the same photo.
    public static func fileName(messageId: String, index: Int, mimeType: String) -> String {
        fileName(messageId: "\(messageId)#\(index)", mimeType: mimeType)
    }
}
