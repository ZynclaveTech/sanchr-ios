import Foundation
import XCTest

@testable import Sanchr

/// What happens to the peer connection after a call ends.
///
/// The duration padding from #95 holds the connection open past hang-up so
/// the server cannot time the call. Two things undid that: the call screen
/// dismissing itself 1.5 s later went through `resetState()`, which cancels
/// the padding and closes the connection; and a late ICE `.connected` on the
/// lingering connection re-entered `.active`, because the handler guarded on
/// the state having an id, and `.ended` has one.
final class CallEndedLingerTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Which states an ICE transition may touch

    func testAnEndedCallIgnoresIceTransitions() {
        XCTAssertFalse(CallState.ended(callId: "c", reason: .normal).acceptsIceTransitions)
    }

    func testAnIdleManagerIgnoresIceTransitions() {
        XCTAssertFalse(CallState.idle.acceptsIceTransitions)
    }

    /// Nothing has been answered yet; a connection cannot be "active".
    func testAnUnansweredIncomingCallIgnoresIceTransitions() {
        XCTAssertFalse(CallState.incoming(callId: "c", callerId: "p", callerName: "P").acceptsIceTransitions)
    }

    func testLiveStatesAcceptIceTransitions() {
        XCTAssertTrue(CallState.outgoing(callId: "c", recipientId: "p").acceptsIceTransitions)
        XCTAssertTrue(CallState.ringing(callId: "c").acceptsIceTransitions)
        XCTAssertTrue(CallState.active(callId: "c", startTime: Date()).acceptsIceTransitions)
        XCTAssertTrue(CallState.reconnecting(callId: "c").acceptsIceTransitions)
    }

    // MARK: - Wiring

    /// The screen going away is not the session ending.
    func testDismissingTheCallScreenDoesNotCancelThePadding() throws {
        let router = code(try source("App/AppRouter.swift"))
        XCTAssertTrue(router.contains("container.callManager.dismissEndedCall()"))
        XCTAssertFalse(router.contains("container.callManager.resetState()"),
                       "resetState cancels the padding; the cover must not call it")

        let manager = code(try source("Platform/Calls/CallManager.swift"))
        let dismiss = try XCTUnwrap(manager.range(of: "func dismissEndedCall() {"))
        let bodyEnd = try XCTUnwrap(manager.range(of: "\n    }\n", range: dismiss.upperBound..<manager.endIndex))
        let body = String(manager[dismiss.upperBound..<bodyEnd.lowerBound])
        XCTAssertFalse(body.contains("paddingManager.cancel()"))
        XCTAssertFalse(body.contains("webRTCClient.close()"))
    }

    /// Signing out still tears everything down.
    func testResetStateStillTearsDown() throws {
        let manager = code(try source("Platform/Calls/CallManager.swift"))
        let reset = try XCTUnwrap(manager.range(of: "func resetState() {"))
        let after = String(manager[reset.upperBound...].prefix(300))
        XCTAssertTrue(after.contains("paddingManager.cancel()"))
        XCTAssertTrue(after.contains("webRTCClient.close()"))
    }

    /// A stale padded close must not be allowed to reach a new call's
    /// connection during the window before the new state is set.
    func testStartingACallCancelsAStalePaddedClose() throws {
        let manager = code(try source("Platform/Calls/CallManager.swift"))
        for entry in ["func startCall(", "func handleIncomingCall("] {
            let start = try XCTUnwrap(manager.range(of: entry))
            let after = String(manager[start.upperBound...].prefix(900))
            XCTAssertTrue(after.contains("paddingManager.cancel()"), "\(entry) must cancel stale padding")
        }
    }

    func testTheIceHandlerGuardsOnState() throws {
        let manager = code(try source("Platform/Calls/CallManager.swift"))
        XCTAssertTrue(manager.contains("guard self.callState.acceptsIceTransitions,"))
    }
}
