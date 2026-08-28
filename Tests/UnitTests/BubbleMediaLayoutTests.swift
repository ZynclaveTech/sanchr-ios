import XCTest
import SanchrShared

@testable import Sanchr

/// Bubble sizing from the attachment's own pixel dimensions. Every sender used
/// to drop them, so this always took the fallback branch: each photo rendered
/// at a fixed 220x180 and then shifted to its real shape once decoded, which is
/// both wrong and a scroll jump.
final class BubbleMediaLayoutTests: XCTestCase {

    private func attachment(
        width: Int? = nil,
        height: Int? = nil,
        mime: String = "image/jpeg"
    ) -> Message.MediaAttachment {
        var a = Message.MediaAttachment(
            url: URL(string: "sanchr-media://x")!,
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: mime, sizeBytes: 1, thumbnailURL: nil
        )
        a.width = width
        a.height = height
        return a
    }

    func testLandscapeIsBoundedByWidth() {
        let size = BubbleMediaLayout.displaySize(for: attachment(width: 4000, height: 2000))
        XCTAssertEqual(size.width, BubbleMediaLayout.maxWidth)
        XCTAssertEqual(size.height, BubbleMediaLayout.maxWidth / 2, accuracy: 1)
    }

    func testPortraitIsBoundedByHeight() {
        let size = BubbleMediaLayout.displaySize(for: attachment(width: 2000, height: 4000))
        XCTAssertEqual(size.height, BubbleMediaLayout.maxHeight)
        XCTAssertLessThanOrEqual(size.width, BubbleMediaLayout.maxWidth)
    }

    func testAspectRatioIsPreserved() {
        let size = BubbleMediaLayout.displaySize(for: attachment(width: 1600, height: 1200))
        XCTAssertEqual(size.width / size.height, 4.0 / 3.0, accuracy: 0.02)
    }

    func testNeverExceedsTheBounds() {
        for (w, h) in [(8000, 100), (100, 8000), (5000, 5000), (1, 1)] {
            let size = BubbleMediaLayout.displaySize(for: attachment(width: w, height: h))
            XCTAssertLessThanOrEqual(size.width, BubbleMediaLayout.maxWidth, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(size.height, BubbleMediaLayout.maxHeight, "\(w)x\(h)")
        }
    }

    /// A panorama scaled purely by width would be a few points tall and
    /// unrecognisable; a floor keeps it tappable.
    func testExtremeRatiosKeepAUsableMinimum() {
        let panorama = BubbleMediaLayout.displaySize(for: attachment(width: 8000, height: 200))
        XCTAssertGreaterThanOrEqual(panorama.height, BubbleMediaLayout.minSide)

        let sliver = BubbleMediaLayout.displaySize(for: attachment(width: 200, height: 8000))
        XCTAssertGreaterThanOrEqual(sliver.width, BubbleMediaLayout.minSide)
    }

    /// Missing or nonsensical dimensions must not produce a zero-sized or
    /// negative bubble.
    func testDegenerateDimensionsFallBack() {
        for a in [attachment(), attachment(width: 0, height: 0), attachment(width: 100, height: nil)] {
            let size = BubbleMediaLayout.displaySize(for: a)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testVideoWithoutDimensionsFallsBackToASquare() {
        let size = BubbleMediaLayout.displaySize(for: attachment(mime: "video/mp4"))
        XCTAssertEqual(size.width, size.height)
    }
}
