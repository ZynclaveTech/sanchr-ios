import XCTest

@testable import Sanchr

/// Pins the reconnect-backoff curve that RealtimeService uses when
/// the realtime message stream drops and needs to retry. The curve
/// is exponential with 30% jitter and a 30s cap:
///
///   attempt 0  -> [1.0, 1.3]s
///   attempt 1  -> [2.0, 2.6]s
///   attempt 2  -> [4.0, 5.2]s
///   attempt 3  -> [8.0, 10.4]s
///   attempt 4  -> [16.0, 20.8]s
///   attempt 5+ -> [30.0, 39.0]s  (cap applied BEFORE jitter)
///
/// The cap before jitter means a runaway reconnect loop never waits
/// more than 39s per attempt, while still spreading retries enough
/// to avoid thundering-herd on a cell tower recovery.
final class ReconnectBackoffTests: XCTestCase {

    func testAttemptZeroFallsInExpectedRange() {
        for _ in 0..<200 {
            let value = RealtimeService.reconnectBackoff(attempt: 0)
            XCTAssertGreaterThanOrEqual(value, 1.0)
            XCTAssertLessThanOrEqual(value, 1.3001)
        }
    }

    func testAttemptThreeFallsInExpectedRange() {
        for _ in 0..<200 {
            let value = RealtimeService.reconnectBackoff(attempt: 3)
            // 2^3 = 8, jitter up to 30% -> [8.0, 10.4]
            XCTAssertGreaterThanOrEqual(value, 8.0)
            XCTAssertLessThanOrEqual(value, 10.4001)
        }
    }

    func testAttemptFiveIsCappedBeforeJitter() {
        for _ in 0..<200 {
            let value = RealtimeService.reconnectBackoff(attempt: 5)
            // 2^5 = 32, capped to 30, then jitter up to 30% of 30 -> [30.0, 39.0]
            XCTAssertGreaterThanOrEqual(value, 30.0)
            XCTAssertLessThanOrEqual(value, 39.0001)
        }
    }

    func testAttemptTenStillCapped() {
        // Runaway attempt counter must not blow the backoff past the cap.
        for _ in 0..<200 {
            let value = RealtimeService.reconnectBackoff(attempt: 10)
            XCTAssertGreaterThanOrEqual(value, 30.0)
            XCTAssertLessThanOrEqual(value, 39.0001)
        }
    }

    func testNegativeAttemptCollapsesToAttemptZero() {
        // Defensive: if the counter ever goes negative (it shouldn't,
        // but we use `max(0, attempt)` inside the function), the curve
        // should still be bounded and sane.
        for _ in 0..<200 {
            let value = RealtimeService.reconnectBackoff(attempt: -5)
            XCTAssertGreaterThanOrEqual(value, 1.0)
            XCTAssertLessThanOrEqual(value, 1.3001)
        }
    }

    func testJitterActuallyVaries() {
        var distinct = Set<Double>()
        for _ in 0..<500 {
            distinct.insert(RealtimeService.reconnectBackoff(attempt: 3))
        }
        // 500 calls with continuous jitter should produce many distinct
        // values — way more than 50 even in a pathological case.
        XCTAssertGreaterThan(distinct.count, 100, "jitter should produce real variation")
    }
}
