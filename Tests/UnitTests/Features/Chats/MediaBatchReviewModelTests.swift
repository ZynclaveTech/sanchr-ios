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
}
