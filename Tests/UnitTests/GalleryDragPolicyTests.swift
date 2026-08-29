import CoreGraphics
import XCTest

@testable import Sanchr

/// The gallery has three things competing for one finger: paging between
/// photos, panning a zoomed photo, and dragging the viewer away. Getting the
/// split wrong silently kills two of them, which is exactly what happened —
/// the dismiss drag was attached as a high-priority gesture and claimed every
/// drag before the pager or the zoomed image could see it.
final class GalleryDragPolicyTests: XCTestCase {

    // MARK: - Which gesture owns the drag

    /// A sideways swipe is the pager's. This is the case that was broken:
    /// swiping between photos did nothing at all.
    func testHorizontalDragsBelongToThePager() {
        XCTAssertFalse(GalleryDragPolicy.isVertical(CGSize(width: -200, height: 0)))
        XCTAssertFalse(GalleryDragPolicy.isVertical(CGSize(width: 200, height: 0)))
    }

    /// A swipe that runs sideways but sags a little is still the pager's. If it
    /// were not, a page turn would start dragging the whole viewer away
    /// halfway through.
    func testASaggingHorizontalSwipeIsStillHorizontal() {
        XCTAssertFalse(GalleryDragPolicy.isVertical(CGSize(width: -180, height: 40)))
    }

    func testDownwardDragsBelongToTheViewer() {
        XCTAssertTrue(GalleryDragPolicy.isVertical(CGSize(width: 0, height: 200)))
        XCTAssertTrue(GalleryDragPolicy.isVertical(CGSize(width: 30, height: 200)))
    }

    /// A perfect diagonal has to resolve one way and stay there. Which way
    /// matters less than that it is decided once and never flips.
    func testAnExactDiagonalIsDecidedNotAmbiguous() {
        let diagonal = CGSize(width: 100, height: 100)
        XCTAssertEqual(
            GalleryDragPolicy.isVertical(diagonal),
            GalleryDragPolicy.isVertical(diagonal),
            "the same drag must always resolve the same way"
        )
    }

    // MARK: - Releasing

    func testAShortDragSnapsBack() {
        XCTAssertFalse(
            GalleryDragPolicy.shouldDismiss(
                translation: CGSize(width: 0, height: 40),
                predictedEnd: CGSize(width: 0, height: 60)
            )
        )
    }

    func testADragPastTheThresholdDismisses() {
        XCTAssertTrue(
            GalleryDragPolicy.shouldDismiss(
                translation: CGSize(width: 0, height: 150),
                predictedEnd: CGSize(width: 0, height: 160)
            )
        )
    }

    /// A flick: the finger lifts early but the projection carries well past.
    func testAFlickDismissesEvenIfTheFingerStoppedShort() {
        XCTAssertTrue(
            GalleryDragPolicy.shouldDismiss(
                translation: CGSize(width: 0, height: 50),
                predictedEnd: CGSize(width: 0, height: 400)
            )
        )
    }

    /// Dragging *up* must never dismiss — the viewer only leaves downward.
    func testUpwardDragsNeverDismiss() {
        XCTAssertFalse(
            GalleryDragPolicy.shouldDismiss(
                translation: CGSize(width: 0, height: -300),
                predictedEnd: CGSize(width: 0, height: -600)
            )
        )
    }

    // MARK: - Backdrop

    func testBackdropIsOpaqueAtRestAndClearWhenFullyDragged() {
        XCTAssertEqual(GalleryDragPolicy.backgroundOpacity(forDrop: 0), 1, accuracy: 0.001)
        XCTAssertEqual(
            GalleryDragPolicy.backgroundOpacity(forDrop: GalleryDragPolicy.fadeDistance),
            0,
            accuracy: 0.001
        )
    }

    /// Dragging further than the fade distance must not produce a negative
    /// opacity, which renders as a hard black flash rather than nothing.
    func testBackdropOpacityNeverGoesNegative() {
        XCTAssertEqual(GalleryDragPolicy.backgroundOpacity(forDrop: 5000), 0, accuracy: 0.001)
    }

    func testBackdropFadesMonotonically() {
        let steps = stride(from: CGFloat(0), through: GalleryDragPolicy.fadeDistance, by: 50)
            .map(GalleryDragPolicy.backgroundOpacity(forDrop:))
        XCTAssertEqual(steps, steps.sorted(by: >), "the backdrop must only ever get clearer")
    }

    /// The flick threshold has to be the looser of the two, or a flick would be
    /// harder to trigger than simply dragging — the opposite of the intent.
    func testTheFlickThresholdIsLooserThanTheDragThreshold() {
        XCTAssertGreaterThan(
            GalleryDragPolicy.dismissPredictedDistance,
            GalleryDragPolicy.dismissDistance
        )
    }

    /// Slack below a tap's wobble, or taps would be swallowed as drags.
    func testMinimumDistanceLeavesRoomForATap() {
        XCTAssertGreaterThan(GalleryDragPolicy.minimumDistance, 0)
        XCTAssertLessThan(GalleryDragPolicy.minimumDistance, GalleryDragPolicy.dismissDistance)
    }
}
