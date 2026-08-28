import Foundation
import UIKit

/// One photo staged for a multi-photo send.
///
/// The full-size bytes stay on disk: a 30-photo batch held in memory would be
/// well over a hundred megabytes, so only the thumbnail is retained and the
/// large preview is decoded on demand for whichever photo is on screen.
struct BatchMediaItem: Identifiable, Equatable {
    let id: UUID
    /// Temp-file JPEG handed to the upload pipeline.
    var fileURL: URL
    var sizeBytes: Int64
    /// Small decoded image for the filmstrip.
    var thumbnail: UIImage?
    /// Computed on the original so it survives editing, as in the single-photo path.
    var blurHash: String?
    var caption: String = ""

    init(
        id: UUID = UUID(),
        fileURL: URL,
        sizeBytes: Int64,
        thumbnail: UIImage? = nil,
        blurHash: String? = nil,
        caption: String = ""
    ) {
        self.id = id
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
        self.thumbnail = thumbnail
        self.blurHash = blurHash
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

    /// Replaces the current photo's bytes after an edit, preserving its
    /// caption, its position, and the blur hash computed from the original.
    func applyEdit(fileURL: URL, sizeBytes: Int64, thumbnail: UIImage?) {
        guard items.indices.contains(currentIndex) else { return }
        items[currentIndex].fileURL = fileURL
        items[currentIndex].sizeBytes = sizeBytes
        if let thumbnail { items[currentIndex].thumbnail = thumbnail }
    }
}
