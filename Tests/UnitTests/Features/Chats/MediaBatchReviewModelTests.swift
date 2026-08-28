import XCTest

@testable import Sanchr

/// The risky part of the multi-photo review screen is index bookkeeping:
/// removing a photo must keep every caption attached to the photo it was
/// written against. Getting it wrong sends someone's caption on another image.
@MainActor
final class MediaBatchReviewModelTests: XCTestCase {

    private func item(_ name: String) -> BatchMediaItem {
        BatchMediaItem(
            fileURL: URL(fileURLWithPath: "/tmp/\(name).jpg"),
            sizeBytes: 10
        )
    }

    private func makeModel(_ names: [String]) -> MediaBatchReviewModel {
        MediaBatchReviewModel(items: names.map(item))
    }

    private func name(of item: BatchMediaItem?) -> String? {
        item?.fileURL.deletingPathExtension().lastPathComponent
    }

    func testStartsOnTheFirstPhoto() {
        let m = makeModel(["a", "b", "c"])
        XCTAssertEqual(name(of: m.current), "a")
        XCTAssertFalse(m.isEmpty)
    }

    func testCaptionAttachesToTheSelectedPhoto() {
        let m = makeModel(["a", "b", "c"])
        m.select(1)
        m.currentCaption = "second"

        XCTAssertEqual(m.items[1].caption, "second")
        XCTAssertTrue(m.items[0].caption.isEmpty)
        XCTAssertTrue(m.items[2].caption.isEmpty)
    }

    /// Removing a photo *before* the current one shifts everything down; the
    /// same photo must stay on screen.
    func testRemovingAnEarlierPhotoKeepsTheCurrentOne() {
        let m = makeModel(["a", "b", "c"])
        m.select(2)
        m.remove(id: m.items[0].id)

        XCTAssertEqual(name(of: m.current), "c")
        XCTAssertEqual(m.currentIndex, 1)
    }

    func testRemovingALaterPhotoLeavesSelectionAlone() {
        let m = makeModel(["a", "b", "c"])
        m.select(0)
        m.remove(id: m.items[2].id)

        XCTAssertEqual(name(of: m.current), "a")
        XCTAssertEqual(m.currentIndex, 0)
    }

    /// Removing the last photo in the strip while it is selected must step
    /// back rather than leave the index pointing past the end.
    func testRemovingTheSelectedLastPhotoStepsBack() {
        let m = makeModel(["a", "b", "c"])
        m.select(2)
        m.remove(id: m.items[2].id)

        XCTAssertEqual(name(of: m.current), "b")
        XCTAssertEqual(m.currentIndex, 1)
    }

    /// The regression this guards: captions must not slide onto neighbours
    /// when something is removed from the middle.
    func testCaptionsSurviveARemoval() {
        let m = makeModel(["a", "b", "c"])
        m.select(0); m.currentCaption = "first"
        m.select(2); m.currentCaption = "third"

        m.remove(id: m.items[1].id)  // drop "b"

        XCTAssertEqual(m.items.map(\.caption), ["first", "third"])
        XCTAssertEqual(name(of: m.current), "c", "the photo being captioned stays on screen")
    }

    func testRemovingEverythingReportsEmpty() {
        let m = makeModel(["a"])
        m.remove(id: m.items[0].id)

        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.current)
    }

    /// Editing swaps the bytes but must not disturb the caption or position.
    func testEditPreservesCaptionAndOrder() {
        let m = makeModel(["a", "b"])
        m.select(1)
        m.currentCaption = "kept"
        m.applyEdit(fileURL: URL(fileURLWithPath: "/tmp/edited.jpg"), sizeBytes: 99, thumbnail: nil)

        XCTAssertEqual(m.items[1].caption, "kept")
        XCTAssertEqual(m.items[1].sizeBytes, 99)
        XCTAssertEqual(name(of: m.items[1]), "edited")
        XCTAssertEqual(name(of: m.items[0]), "a", "the other photo is untouched")
        XCTAssertEqual(m.currentIndex, 1)
    }

    func testSelectIgnoresOutOfRange() {
        let m = makeModel(["a", "b"])
        m.select(9)
        XCTAssertEqual(m.currentIndex, 0)
    }

    // MARK: - Mixed photo/video batches

    private func video(_ name: String, seconds: Double? = 12) -> BatchMediaItem {
        BatchMediaItem(
            kind: .video(durationSeconds: seconds),
            fileURL: URL(fileURLWithPath: "/tmp/\(name).mp4"),
            sizeBytes: 100
        )
    }

    func testVideoCarriesItsMimeType() {
        XCTAssertEqual(video("clip").mimeType, "video/mp4")
        XCTAssertEqual(item("still").mimeType, "image/jpeg")
    }

    func testEditingIsOfferedForPhotosOnly() {
        let m = MediaBatchReviewModel(items: [item("a"), video("clip")])
        XCTAssertTrue(m.canEditCurrent)
        m.select(1)
        XCTAssertFalse(m.canEditCurrent, "the still editor cannot act on a clip")
    }

    /// The editor produces a still. Applying one to a video would replace the
    /// clip with a single frame of it — silent data loss.
    func testApplyEditIsRefusedOnAVideo() {
        let m = MediaBatchReviewModel(items: [video("clip")])
        m.applyEdit(fileURL: URL(fileURLWithPath: "/tmp/frame.jpg"), sizeBytes: 5, thumbnail: nil)

        XCTAssertEqual(name(of: m.current), "clip")
        XCTAssertEqual(m.items[0].sizeBytes, 100)
    }

    func testCaptionsWorkOnVideosToo() {
        let m = MediaBatchReviewModel(items: [item("a"), video("clip")])
        m.select(1)
        m.currentCaption = "on the clip"

        XCTAssertEqual(m.items[1].caption, "on the clip")
        XCTAssertTrue(m.items[0].caption.isEmpty)
    }

    func testRemovalWorksAcrossAMixedBatch() {
        let m = MediaBatchReviewModel(items: [item("a"), video("clip"), item("c")])
        m.select(2)
        m.remove(id: m.items[1].id)

        XCTAssertEqual(name(of: m.current), "c")
        XCTAssertEqual(m.items.map { $0.kind.isVideo }, [false, false])
    }

    func testDurationBadgeFormatting() {
        XCTAssertEqual(MediaBatchReviewView.durationText(0), "0:00")
        XCTAssertEqual(MediaBatchReviewView.durationText(9), "0:09")
        XCTAssertEqual(MediaBatchReviewView.durationText(75), "1:15")
        XCTAssertEqual(MediaBatchReviewView.durationText(600), "10:00")
        // AVFoundation hands back NaN for an unreadable asset.
        XCTAssertNil(MediaBatchReviewView.durationText(.nan))
        XCTAssertNil(MediaBatchReviewView.durationText(-1))
    }
}
