import UIKit
import WebRTC
import XCTest

@testable import Sanchr

/// Portrait video arrived at the far end as landscape: `FilteredVideoCapturer`
/// replaced `RTCCameraVideoCapturer` to apply filters and tagged every frame
/// `._0`, so the camera's native landscape buffers were never rotated back.
/// This is the table that fixes it, mirroring `RTCCameraVideoCapturer`.
final class VideoRotationTests: XCTestCase {

    private func rotation(_ o: UIDeviceOrientation, front: Bool) -> RTCVideoRotation {
        FilteredVideoCapturer.rotation(for: o, isFrontCamera: front)
    }

    /// The common case, and the one that was broken.
    func testPortraitIsRotatedRegardlessOfCamera() {
        XCTAssertEqual(rotation(.portrait, front: true), ._90)
        XCTAssertEqual(rotation(.portrait, front: false), ._90)
    }

    func testUpsideDownPortrait() {
        XCTAssertEqual(rotation(.portraitUpsideDown, front: true), ._270)
        XCTAssertEqual(rotation(.portraitUpsideDown, front: false), ._270)
    }

    /// Landscape is the only case where the camera matters: the front sensor is
    /// mounted the other way up, so getting this wrong flips the picture 180°.
    func testLandscapeDependsOnWhichCamera() {
        XCTAssertEqual(rotation(.landscapeLeft, front: true), ._180)
        XCTAssertEqual(rotation(.landscapeLeft, front: false), ._0)
        XCTAssertEqual(rotation(.landscapeRight, front: true), ._0)
        XCTAssertEqual(rotation(.landscapeRight, front: false), ._180)
    }

    /// A phone laid flat reports faceUp/faceDown, which carry no usable
    /// rotation. They must not produce something wild.
    func testFlatAndUnknownOrientationsFallBackToPortrait() {
        for o in [UIDeviceOrientation.faceUp, .faceDown, .unknown] {
            XCTAssertEqual(rotation(o, front: true), ._90, "\(o.rawValue) should default to portrait")
            XCTAssertEqual(rotation(o, front: false), ._90)
        }
    }

    /// Nothing may still report `._0` for a portrait-held phone — that is
    /// precisely the bug.
    func testPortraitIsNeverUnrotated() {
        XCTAssertNotEqual(rotation(.portrait, front: true), ._0)
        XCTAssertNotEqual(rotation(.portrait, front: false), ._0)
    }
}
