import SwiftUI
import XCTest

@testable import Sanchr

/// Crop could previously only be resized from its corners, never repositioned.
/// These cover the move, whose whole job is clamping: a crop that walks off the
/// edge of the image produces a crop of nothing.
final class ImageEditorCropMoveTests: XCTestCase {

    /// 200×100pt on screen, so a normalised delta is easy to reason about:
    /// 20pt right is 0.1 of the width.
    private let frame = CGRect(x: 0, y: 0, width: 200, height: 100)

    private func overlay(cropRect: CGRect) -> ImageEditorCropOverlay {
        ImageEditorCropOverlay(
            cropRect: .constant(cropRect),
            imageFrame: frame,
            onAspect: { _ in }
        )
    }

    func testMoveTranslatesByTheNormalisedDelta() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let moved = overlay(cropRect: start)
            .moved(startRect: start, totalDelta: CGSize(width: 20, height: 10))

        XCTAssertEqual(moved.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.minY, 0.3, accuracy: 0.0001)
    }

    func testMoveKeepsTheCropSize() {
        let start = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.6)
        let moved = overlay(cropRect: start)
            .moved(startRect: start, totalDelta: CGSize(width: 30, height: -5))

        XCTAssertEqual(moved.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.6, accuracy: 0.0001)
    }

    func testMoveClampsAtTheTopLeft() {
        let start = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let moved = overlay(cropRect: start)
            .moved(startRect: start, totalDelta: CGSize(width: -500, height: -500))

        XCTAssertEqual(moved.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(moved.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.5, accuracy: 0.0001, "clamping must not shrink the crop")
    }

    /// The far edge is the one that actually bites: the crop's *trailing* edge
    /// has to stop at 1, not its origin.
    func testMoveClampsAtTheBottomRight() {
        let start = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4)
        let moved = overlay(cropRect: start)
            .moved(startRect: start, totalDelta: CGSize(width: 500, height: 500))

        XCTAssertEqual(moved.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(moved.maxY, 1, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.4, accuracy: 0.0001)
    }

    /// A full-frame crop has nowhere to go; it must stay put rather than
    /// producing a negative origin.
    func testFullFrameCropCannotMove() {
        let start = CGRect(x: 0, y: 0, width: 1, height: 1)
        let moved = overlay(cropRect: start)
            .moved(startRect: start, totalDelta: CGSize(width: 40, height: 40))

        XCTAssertEqual(moved, start)
    }
}
