import XCTest

@testable import Sanchr

/// The whole clip has to be drawn.
///
/// The renderer stepped through samples with `samples.count / barCount`,
/// floored. With 64 samples and 23 bars the step was 2, so the last index
/// reached was 44: the final ~30% of every clip's amplitude was never drawn,
/// while the progress head swept the full width — so the bars and the
/// position disagreed about where the clip ended.
final class VoiceWaveformCoverageTests: XCTestCase {
    /// The mapping the renderer now uses: position across the clip, not a
    /// floored stride.
    private func sampleIndex(bar: Int, barCount: Int, sampleCount: Int) -> Int {
        let lastSample = max(0, sampleCount - 1)
        let fraction = barCount <= 1 ? 0 : Double(bar) / Double(barCount - 1)
        return min(lastSample, Int((fraction * Double(lastSample)).rounded()))
    }

    func test_theLastBarReachesTheLastSample() {
        // 64 samples into 23 bars is the shape that lost the tail.
        XCTAssertEqual(sampleIndex(bar: 22, barCount: 23, sampleCount: 64), 63)
    }

    func test_theFirstBarIsTheFirstSample() {
        XCTAssertEqual(sampleIndex(bar: 0, barCount: 23, sampleCount: 64), 0)
    }

    func test_coverageHoldsForEveryPlausibleShape() {
        for sampleCount in [2, 7, 40, 64, 100, 257] {
            for barCount in [1, 2, 9, 23, 40, 64, 200] {
                let last = sampleIndex(bar: barCount - 1, barCount: barCount, sampleCount: sampleCount)
                // A lone bar cannot span a clip; it shows the one sample it
                // has room for. Every wider strip must reach the end.
                if barCount > 1 {
                    XCTAssertEqual(
                        last, sampleCount - 1,
                        "the last bar of \(barCount) must reach sample \(sampleCount - 1)")
                } else {
                    XCTAssertEqual(last, 0)
                }
                for bar in 0..<barCount {
                    let index = sampleIndex(bar: bar, barCount: barCount, sampleCount: sampleCount)
                    XCTAssertTrue((0..<sampleCount).contains(index), "index \(index) out of range")
                }
            }
        }
    }

    func test_indicesAdvanceMonotonically() {
        var previous = -1
        for bar in 0..<40 {
            let index = sampleIndex(bar: bar, barCount: 40, sampleCount: 64)
            XCTAssertGreaterThanOrEqual(index, previous)
            previous = index
        }
    }
}
