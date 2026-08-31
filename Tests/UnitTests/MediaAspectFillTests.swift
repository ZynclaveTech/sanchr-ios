import CoreGraphics
import SwiftUI
import XCTest

@testable import Sanchr

/// Whether a pre-send preview fills the screen or fits inside it.
///
/// The close button and caption row are pinned to the screen, so black bands
/// leave them stranded away from the picture's real edges. Filling removes the
/// bands; filling too eagerly crops away what you are about to send.
final class MediaAspectFillTests: XCTestCase {

    /// A modern phone screen.
    private let screen = CGSize(width: 393, height: 852)

    private func mode(_ ratio: CGFloat?) -> ContentMode {
        MediaAspectFill.presentationRatio(content: ratio, container: screen).contentMode
    }

    /// A clip shot on the phone, in the shape of the phone. This is the case
    /// that looked wrong: deep bands with the chrome stranded at the edges.
    func testAPhoneShotClipFillsTheScreen() {
        XCTAssertEqual(mode(9.0 / 16.0), .fill)
    }

    func testAClipTheExactShapeOfTheScreenFills() {
        XCTAssertEqual(mode(393.0 / 852.0), .fill)
    }

    /// Filling a 4:3 clip into a tall screen would hide about a third of the
    /// frame, which is worse than the band it removes.
    func testAFourThreeClipKeepsItsBands() {
        XCTAssertEqual(mode(4.0 / 3.0), .fit)
    }

    func testALandscapeClipKeepsItsBands() {
        XCTAssertEqual(mode(16.0 / 9.0), .fit)
    }

    /// Before the track has been read there is nothing to judge, and guessing
    /// a crop from nothing is worse than a moment of letterbox.
    func testAnUnknownRatioFits() {
        XCTAssertEqual(mode(nil), .fit)
    }

    func testDegenerateInputsFit() {
        XCTAssertEqual(mode(0), .fit)
        XCTAssertEqual(
            MediaAspectFill.presentationRatio(
                content: 0.5, container: CGSize(width: 0, height: 0)
            ).contentMode,
            .fit
        )
    }

    /// Divergence is a proportion, not a difference: the gap between 0.5 and
    /// 0.6 matters far more than the same gap between 2.5 and 2.6.
    func testDivergenceIsProportional() {
        let square = CGSize(width: 100, height: 100)
        // Both are 0.1 away from 1.0 in absolute terms; neither should be
        // treated as further from square than the other by much.
        let narrower = MediaAspectFill.presentationRatio(content: 0.9, container: square)
        let wider = MediaAspectFill.presentationRatio(content: 1.0 / 0.9, container: square)
        XCTAssertEqual(narrower.contentMode, wider.contentMode)
    }
}
