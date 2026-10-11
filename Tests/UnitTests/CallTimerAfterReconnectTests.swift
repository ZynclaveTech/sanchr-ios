import XCTest

@testable import Sanchr

/// A call that drops and comes back is the same call. Its timer used to
/// restart from 00:00 on every reconnect.
final class CallTimerAfterReconnectTests: XCTestCase {

    func testAReconnectedCallIsCountedFromWhenItFirstConnected() {
        let connected = Date(timeIntervalSince1970: 1_800_000_000)
        let reconnected = connected.addingTimeInterval(95)

        XCTAssertEqual(CallManager.startTime(resuming: connected, now: reconnected), connected)
    }

    func testACallConnectingForTheFirstTimeIsCountedFromNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(CallManager.startTime(resuming: nil, now: now), now)
    }

    /// The reconnect path has to go through the rule above, and keep what it
    /// used: read from the source, because driving a real ICE reconnect needs
    /// a peer connection.
    func testTheReconnectPathKeepsTheOriginalStart() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Platform/Calls/CallManager.swift"),
            encoding: .utf8)
        let handler = try XCTUnwrap(
            source.range(of: "didChangeConnectionState state: RTCIceConnectionState")
        )
        let body = source[handler.upperBound...].prefix(2_000)

        XCTAssertTrue(body.contains("Self.startTime(resuming: self.callStartTime, now: Date())"))
        XCTAssertTrue(body.contains("self.callStartTime = startTime"))
        XCTAssertFalse(body.contains("let startTime = Date()"), "a reconnect must not restart the clock")
    }
}
