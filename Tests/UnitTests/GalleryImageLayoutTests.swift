import CoreGraphics
import XCTest

@testable import Sanchr

/// The scrollable content of a zoomable page must be the image and nothing
/// else. Sizing the image view to the whole viewport and leaning on
/// `.scaleAspectFit` looks identical at rest, but the empty bars either side of
/// the picture become part of what scrolls — so zooming in and dragging pushed
/// the photo off into black space.
final class GalleryImageLayoutTests: XCTestCase {

    private let viewport = CGSize(width: 440, height: 956)

    /// A portrait photo is limited by width and must leave no horizontal slack.
    func testAPortraitImageFillsTheWidth() {
        let fitted = GalleryImageLayout.fittedSize(
            for: CGSize(width: 1080, height: 1920),
            in: viewport
        )
        XCTAssertEqual(fitted.width, viewport.width, accuracy: 1)
        XCTAssertLessThan(fitted.height, viewport.height)
    }

    /// A landscape photo is limited by height instead.
    func testALandscapeImageFillsTheHeight() {
        let fitted = GalleryImageLayout.fittedSize(
            for: CGSize(width: 4000, height: 3000),
            in: viewport
        )
        XCTAssertLessThan(fitted.width, viewport.width + 1)
        XCTAssertLessThan(fitted.height, viewport.height)
        XCTAssertEqual(fitted.width, viewport.width, accuracy: 1)
    }

    /// Never larger than the viewport in either direction, or the page would
    /// start out already scrolled.
    func testNothingExceedsTheViewport() {
        for size in [
            CGSize(width: 8000, height: 100),
            CGSize(width: 100, height: 8000),
            CGSize(width: 5000, height: 5000),
        ] {
            let fitted = GalleryImageLayout.fittedSize(for: size, in: viewport)
            XCTAssertLessThanOrEqual(fitted.width, viewport.width + 1, "\(size)")
            XCTAssertLessThanOrEqual(fitted.height, viewport.height + 1, "\(size)")
        }
    }

    /// The point of the change: the fitted rect keeps the image's proportions,
    /// so what scrolls is the picture rather than the picture plus its bars.
    func testAspectRatioIsPreserved() {
        let source = CGSize(width: 1600, height: 900)
        let fitted = GalleryImageLayout.fittedSize(for: source, in: viewport)
        XCTAssertEqual(
            fitted.width / fitted.height,
            source.width / source.height,
            accuracy: 0.01
        )
    }

    /// A square viewport and a square image should agree exactly.
    func testASquareImageInASquareViewportFillsIt() {
        let square = CGSize(width: 500, height: 500)
        let fitted = GalleryImageLayout.fittedSize(
            for: CGSize(width: 2000, height: 2000),
            in: square
        )
        XCTAssertEqual(fitted, square)
    }

    /// Degenerate input must fall back to the viewport rather than collapse the
    /// page to nothing. Showing the image slightly wrong beats showing none.
    func testDegenerateInputFallsBackToTheViewport() {
        XCTAssertEqual(GalleryImageLayout.fittedSize(for: nil, in: viewport), viewport)
        XCTAssertEqual(GalleryImageLayout.fittedSize(for: .zero, in: viewport), viewport)
        XCTAssertEqual(
            GalleryImageLayout.fittedSize(for: CGSize(width: 100, height: 0), in: viewport),
            viewport
        )
    }

    /// Called during layout before the view has a size.
    func testAZeroViewportDoesNotDivideByZero() {
        let fitted = GalleryImageLayout.fittedSize(
            for: CGSize(width: 100, height: 100),
            in: .zero
        )
        XCTAssertEqual(fitted, .zero)
    }

    /// Sizes land on whole points. A fractional height leaves a hairline of
    /// backdrop along one edge that reads as a rendering fault.
    func testSizesAreWholePoints() {
        let fitted = GalleryImageLayout.fittedSize(
            for: CGSize(width: 1023, height: 767),
            in: viewport
        )
        XCTAssertEqual(fitted.width, fitted.width.rounded())
        XCTAssertEqual(fitted.height, fitted.height.rounded())
    }
}
