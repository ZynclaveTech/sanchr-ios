import Foundation

/// What the host app handed us, normalized to a single value the rest of
/// the extension can reason about.
///
/// `loadFileRepresentation` returns URLs that the system reclaims after the
/// completion handler returns, so the loader copies every file payload into
/// `AppGroup.mediaCacheURL` before constructing one of these cases. The
/// `fileURL` on every case is therefore stable for the lifetime of the share
/// session and safe to hand off to the send pipeline.
enum SharePayload: Equatable {
    case text(String)
    case url(URL)
    case image(fileURL: URL, sizeBytes: Int64)
    case video(fileURL: URL, sizeBytes: Int64, durationSeconds: Double)
    case audio(fileURL: URL, sizeBytes: Int64, durationSeconds: Double)
    case file(fileURL: URL, sizeBytes: Int64, filename: String)
    /// Multiple attachments shared in a single invocation. Always >= 2 entries.
    /// `multi` payloads are never themselves nested.
    indirect case multi([SharePayload])

    /// Deletes the copies. A sent file is the message's local copy and must
    /// stay; call this only when nothing was sent — a cancelled share, or a
    /// send that failed for every recipient.
    func removeFiles() {
        for url in fileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total bytes across this payload (recursive for `.multi`).
    var sizeBytes: Int64 {
        switch self {
        case .text, .url:
            return 0
        case .image(_, let s),
             .video(_, let s, _),
             .audio(_, let s, _),
             .file(_, let s, _):
            return s
        case .multi(let parts):
            return parts.reduce(0) { $0 + $1.sizeBytes }
        }
    }

    /// File URLs backing this payload, used by the send pipeline and for
    /// cleanup of the App Group media cache after sending finishes.
    var fileURLs: [URL] {
        switch self {
        case .text, .url:
            return []
        case .image(let u, _),
             .video(let u, _, _),
             .audio(let u, _, _),
             .file(let u, _, _):
            return [u]
        case .multi(let parts):
            return parts.flatMap { $0.fileURLs }
        }
    }

    /// Hard cap before the picker even loads. Applied per-attachment AND to
    /// the aggregate of a `.multi` payload.
    static let maxSizeBytes: Int64 = 100 * 1024 * 1024
}

enum SharePayloadError: Error, Equatable {
    case unsupportedType
    case tooLarge(actualBytes: Int64)
    case loadFailed(String)
    case nothingShared
}
