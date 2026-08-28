import CoreGraphics
import XCTest
import SanchrShared

@testable import Sanchr

/// Which clips get re-encoded, and whether the result is worth sending.
///
/// Compression is an optimisation, so every judgement here fails towards
/// sending the original: a wrong "compress" costs quality and time, and in the
/// worst case produces a *larger* file than the camera did.
final class VideoCompressionPolicyTests: XCTestCase {

    private let mb: Int64 = 1024 * 1024

    private func decide(_ size: CGSize, _ bytes: Int64) -> VideoCompressionPolicy.Decision {
        VideoCompressionPolicy.decide(pixelSize: size, byteCount: bytes)
    }

    // MARK: - What gets compressed

    /// The case this exists for: a camera original is far larger than a chat
    /// needs.
    func testFourKIsCompressed() {
        XCTAssertEqual(decide(CGSize(width: 3840, height: 2160), 350 * mb), .compress)
    }

    func testPortraitIsJudgedByItsLongEdge() {
        // 1080x1920 is a portrait 1080p — same pixels as landscape, so it must
        // be treated the same rather than looking "narrow enough".
        XCTAssertEqual(decide(CGSize(width: 1080, height: 1920), 90 * mb), .compress)
    }

    /// A clip already at 720p but absurdly heavy is still worth re-encoding.
    func testAlreadyTargetResolutionButOversizedIsCompressed() {
        XCTAssertEqual(decide(CGSize(width: 1280, height: 720), 200 * mb), .compress)
    }

    // MARK: - What is left alone

    /// Re-encoding something already small wastes time and battery and can
    /// make it bigger.
    func testSmallClipsAreSentAsTheyAre() {
        guard case .sendOriginal = decide(CGSize(width: 1920, height: 1080), 1 * mb) else {
            return XCTFail("a 1 MB clip should not be re-encoded")
        }
    }

    func testAlreadyWithinTargetIsLeftAlone() {
        guard case .sendOriginal = decide(CGSize(width: 1280, height: 720), 8 * mb) else {
            return XCTFail("a sensibly encoded 720p clip should be left alone")
        }
    }

    /// Unreadable input must not be re-encoded blind — the file is still
    /// perfectly sendable as it is.
    func testUnknownDimensionsSendTheOriginal() {
        guard case .sendOriginal = decide(.zero, 100 * mb) else {
            return XCTFail("unknown dimensions must not trigger a blind re-encode")
        }
    }

    func testUnknownSizeSendsTheOriginal() {
        guard case .sendOriginal = decide(CGSize(width: 3840, height: 2160), 0) else {
            return XCTFail("unknown size must not trigger a re-encode")
        }
    }

    // MARK: - Keeping the result

    func testAClearSavingIsKept() {
        XCTAssertTrue(
            VideoCompressionPolicy.isWorthKeeping(compressedBytes: 20 * mb, originalBytes: 200 * mb)
        )
    }

    /// Export can enlarge an already-compressed or very short clip. Sending
    /// that would make the feature actively harmful.
    func testALargerResultIsRejected() {
        XCTAssertFalse(
            VideoCompressionPolicy.isWorthKeeping(compressedBytes: 120 * mb, originalBytes: 100 * mb)
        )
    }

    /// A marginal saving is not worth the quality loss.
    func testAMarginalSavingIsRejected() {
        XCTAssertFalse(
            VideoCompressionPolicy.isWorthKeeping(compressedBytes: 95 * mb, originalBytes: 100 * mb)
        )
    }

    func testDegenerateSizesAreRejected() {
        XCTAssertFalse(VideoCompressionPolicy.isWorthKeeping(compressedBytes: 0, originalBytes: 100))
        XCTAssertFalse(VideoCompressionPolicy.isWorthKeeping(compressedBytes: 100, originalBytes: 0))
    }
}
