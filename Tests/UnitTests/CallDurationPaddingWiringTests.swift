import Foundation
import XCTest

@testable import Sanchr

/// Hiding how long a call lasted.
///
/// `CallDurationPaddingManager` computes the buckets and delays teardown so
/// the server cannot time a call by watching its media stop. It was
/// constructed, it had tests, and the only thing anything ever called on it
/// was `cancel()` — so every call reported its exact length.
final class CallDurationPaddingWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var manager: String {
        get throws { try source("Platform/Calls/CallManager.swift") }
    }

    // MARK: - The buckets

    func testAShortCallIsReportedAsAMinute() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(9)
        XCTAssertEqual(
            CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end),
            start.addingTimeInterval(60)
        )
    }

    func testACallIsRoundedUpToTheNextBucketNotTheNearest() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(61)
        XCTAssertEqual(
            CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end),
            start.addingTimeInterval(300)
        )
    }

    /// Past the last bucket there is nothing left to round to, and holding a
    /// connection open indefinitely would be worse than the leak.
    func testAVeryLongCallStopsAtTheLastBucket() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(60 * 60 * 5)
        XCTAssertEqual(
            CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: end),
            start.addingTimeInterval(3600)
        )
    }

    // MARK: - When it applies

    /// A call that never connected has no duration to hide, and padding one
    /// would hold a connection open for a minute after a decline.
    func testACallThatNeverConnectedIsNotPadded() throws {
        let body = code(try manager)
        XCTAssertTrue(
            body.contains("guard let callStart else {\n            webRTCClient.close()\n            return\n        }"),
            "no start time means it never connected"
        )
    }

    /// A call that began while the padding was still waiting owns the
    /// connection. Closing then would tear down the new call to finish hiding
    /// the length of the old one.
    func testPaddingDoesNotCloseAConnectionANewCallHasTaken() throws {
        let body = code(try manager)
        XCTAssertTrue(body.contains("guard Self.isBetweenCalls(self.callState) else"))
        XCTAssertTrue(CallManager.isBetweenCalls(.idle))
        XCTAssertTrue(CallManager.isBetweenCalls(.ended(callId: "c", reason: .normal)))
        XCTAssertFalse(
            CallManager.isBetweenCalls(.active(callId: "c", startTime: Date())),
            "an active call owns the connection"
        )
    }

    // MARK: - Wiring

    func testTeardownGoesThroughThePadding() throws {
        let body = code(try manager)
        XCTAssertTrue(body.contains("closePeerConnection(paddingFrom: callStartTime)"))
    }

    /// Capture has nothing to do with what the server can time, so it stops at
    /// hang-up whether or not the connection lingers.
    func testCaptureStopsImmediately() throws {
        let body = code(try manager)
        let stop = try XCTUnwrap(body.range(of: "webRTCClient.stopLocalMedia()\n        closePeerConnection"))
        XCTAssertNotNil(stop)
    }
}
