import Foundation
import SanchrShared
import UIKit

/// One photo staged for a multi-photo send.
///
/// The full-size bytes stay on disk: a 30-photo batch held in memory would be
/// well over a hundred megabytes, so only the thumbnail is retained and the
/// large preview is decoded on demand for whichever photo is on screen.
struct BatchMediaItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case photo
        /// Videos ride along in the same batch. They are previewed with a
        /// player and cannot be sent through the still-image editor.
        case video(durationSeconds: Double?)

        var isVideo: Bool {
            if case .video = self { return true }
            return false
        }
    }

    let id: UUID
    var kind: Kind
    /// Temp-file JPEG (photos) or MP4 (videos) handed to the upload pipeline.
    var fileURL: URL
    var sizeBytes: Int64
    /// Small decoded image for the filmstrip.
    var thumbnail: UIImage?
    /// On-disk poster frame, which a video attachment carries to the recipient
    /// for its bubble. Nil for photos.
    var posterURL: URL?
    /// Computed on the original so it survives editing, as in the single-photo path.
    var blurHash: String?
    /// Pixel dimensions, carried to the recipient so the bubble can be sized
    /// before the media downloads. Nil only when they could not be read.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var caption: String = ""

    var mimeType: String { kind.isVideo ? "video/mp4" : "image/jpeg" }

    /// The attachment handed to the send path.
    ///
    /// `url` is always the media file. The upload reads exactly this, so a
    /// video whose `url` pointed at its poster uploaded a 30 KB still labelled
    /// `video/mp4` and never sent the clip at all — the receiver's player was
    /// then handed a JPEG. The poster belongs in `thumbnailURL`.
    func sendableAttachment() -> Message.MediaAttachment {
        var attachment = Message.MediaAttachment(
            url: fileURL,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            thumbnailURL: posterURL
        )
        attachment.blurHash = blurHash
        attachment.width = pixelWidth
        attachment.height = pixelHeight
        if case .video(let duration) = kind {
            attachment.durationSeconds = duration
        }
        if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attachment.caption = caption
        }
        return attachment
    }

    init(
        id: UUID = UUID(),
        kind: Kind = .photo,
        fileURL: URL,
        sizeBytes: Int64,
        thumbnail: UIImage? = nil,
        posterURL: URL? = nil,
        blurHash: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        caption: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
        self.thumbnail = thumbnail
        self.posterURL = posterURL
        self.blurHash = blurHash
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.caption = caption
    }
}

/// Selection and caption state behind the multi-photo review screen.
///
/// Split from the view because the fiddly part is index bookkeeping: removing a
/// photo must keep the highlighted item and every caption attached to the right
/// photo. Getting that wrong sends someone's caption on the wrong image.
@MainActor
@Observable
final class MediaBatchReviewModel {
    private(set) var items: [BatchMediaItem]
    private(set) var currentIndex: Int = 0

    init(items: [BatchMediaItem]) {
        self.items = items
    }

    var current: BatchMediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var isEmpty: Bool { items.isEmpty }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    /// Caption for the photo on screen. Addressed by identity rather than by
    /// index so a removal elsewhere cannot redirect it onto another photo.
    var currentCaption: String {
        get { current?.caption ?? "" }
        set {
            guard let id = current?.id,
                  let idx = items.firstIndex(where: { $0.id == id })
            else { return }
            items[idx].caption = newValue
        }
    }

    /// Drops one photo and keeps the selection sensible: stay put when a later
    /// photo goes, step back when the current or an earlier one does, and never
    /// point past the end.
    func remove(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: idx)
        if items.isEmpty {
            currentIndex = 0
        } else if idx < currentIndex {
            currentIndex -= 1
        } else if currentIndex >= items.count {
            currentIndex = items.count - 1
        }
    }

    /// Whether the photo on screen can go through the still-image editor.
    var canEditCurrent: Bool {
        guard let current else { return false }
        return !current.kind.isVideo
    }

    /// Replaces the current photo's bytes after an edit, preserving its
    /// caption, its position, and the blur hash computed from the original.
    ///
    /// Refuses on a video: the editor produces a still, so applying it would
    /// silently replace the clip with a frame of it.
    func applyEdit(
        fileURL: URL,
        sizeBytes: Int64,
        thumbnail: UIImage?,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        guard items.indices.contains(currentIndex),
              !items[currentIndex].kind.isVideo
        else { return }
        items[currentIndex].fileURL = fileURL
        items[currentIndex].sizeBytes = sizeBytes
        if let thumbnail { items[currentIndex].thumbnail = thumbnail }
        // Cropping and rotating change the shape, so the recorded dimensions
        // have to follow or the bubble would be sized for the original.
        if let pixelWidth { items[currentIndex].pixelWidth = pixelWidth }
        if let pixelHeight { items[currentIndex].pixelHeight = pixelHeight }
    }
}
