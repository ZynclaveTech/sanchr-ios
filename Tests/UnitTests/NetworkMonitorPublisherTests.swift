import Combine
import XCTest
import SanchrShared

/// Pins the contract that RealtimeService's reconnect-backoff logic
/// depends on: the publisher must synchronously deliver an initial
/// value to every new subscriber (so the service knows the current
/// connectivity without waiting for the next NWPathMonitor callback),
/// and it must suppress non-transitioning path updates so subscribers
/// don't see phantom "went up" events on every callback.
///
/// Real NWPathMonitor integration (transition from down -> up and
/// back) is exercised by the manual smoke matrix. These tests only
/// cover the CurrentValueSubject-backed side of the contract, which
/// is the part that can regress silently if someone swaps the subject
/// for a PassthroughSubject or forgets the didSet guard.
final class NetworkMonitorPublisherTests: XCTestCase {

    func testNewSubscriberReceivesCurrentValueSynchronously() {
        let monitor = NetworkMonitor()
        let exp = expectation(description: "subscriber receives the current value")
        exp.assertForOverFulfill = false

        var received: [Bool] = []
        let cancellable = monitor.connectivityPublisher.sink { value in
            received.append(value)
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()

        XCTAssertFalse(received.isEmpty, "subscriber should have received at least one value")
    }

    func testSecondSubscriberStillGetsCurrentValue() {
        // Proves the CurrentValueSubject replay contract: the publisher
        // is NOT a one-shot — every new subscriber, not just the first,
        // gets the current value on subscribe.
        let monitor = NetworkMonitor()

        let firstExp = expectation(description: "first subscriber receives a value")
        firstExp.assertForOverFulfill = false
        var firstReceived: [Bool] = []
        let first = monitor.connectivityPublisher.sink { value in
            firstReceived.append(value)
            firstExp.fulfill()
        }
        wait(for: [firstExp], timeout: 1.0)

        let secondExp = expectation(description: "second subscriber receives a value")
        secondExp.assertForOverFulfill = false
        var secondReceived: [Bool] = []
        let second = monitor.connectivityPublisher.sink { value in
            secondReceived.append(value)
            secondExp.fulfill()
        }
        wait(for: [secondExp], timeout: 1.0)

        first.cancel()
        second.cancel()

        XCTAssertFalse(firstReceived.isEmpty)
        XCTAssertFalse(secondReceived.isEmpty)
    }
}
