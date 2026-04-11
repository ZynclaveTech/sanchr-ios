// Tests/UnitTests/Platform/Calls/CallDurationPaddingManagerTests.swift
import XCTest
@testable import Sanchr

final class CallDurationPaddingManagerTests: XCTestCase {

    // MARK: - paddingEnd

    func test_paddingEnd_30secCall_roundsUpTo1MinBucket() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = Date(timeIntervalSince1970: 30)
        let target = CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end)
        XCTAssertEqual(target.timeIntervalSince1970, 60, accuracy: 0.001)
    }

    func test_paddingEnd_exactlyAtBoundary_staysInBucket() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = Date(timeIntervalSince1970: 300)  // exactly 5 min
        let target = CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end)
        XCTAssertEqual(target.timeIntervalSince1970, 300, accuracy: 0.001)
    }

    func test_paddingEnd_61minCall_capsAt60MinBucket() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = Date(timeIntervalSince1970: 3660)  // 61 min — exceeds all buckets
        let target = CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end)
        XCTAssertEqual(target.timeIntervalSince1970, 3600, accuracy: 0.001)  // capped at 60-min bucket
    }

    func test_paddingEnd_7minCall_roundsUpTo15MinBucket() {
        let start = Date(timeIntervalSince1970: 0)
        let end   = Date(timeIntervalSince1970: 420)  // 7 min
        let target = CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end)
        XCTAssertEqual(target.timeIntervalSince1970, 900, accuracy: 0.001)  // next bucket: 15 min
    }

    // MARK: - padThenComplete

    func test_padThenComplete_callsCompletionAfterDelay() async {
        let mgr = CallDurationPaddingManager()
        let start = Date()
        let end   = Date()  // 0-duration call → pads to 1 min
        // Override: target is in the past → completes immediately
        let target = Date(timeIntervalSinceNow: -1)

        let expectation = XCTestExpectation(description: "completion called")
        mgr.padThenComplete(target: target) {
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
        _ = (start, end)  // suppress unused
    }

    func test_cancel_preventsCompletion() async {
        let mgr = CallDurationPaddingManager()
        let target = Date(timeIntervalSinceNow: 10)  // 10 seconds in the future

        var completionCalled = false
        mgr.padThenComplete(target: target) { completionCalled = true }
        mgr.cancel()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(completionCalled)
    }
}
