import Foundation
import XCTest

@testable import Sanchr

/// The main UI must not wait on launch network work it does not need.
/// Before this, five or six sequential round trips ran before
/// `sessionReady` flipped, so even the cached chats list could not draw.
final class SessionReadyTests: XCTestCase {

    private var app: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("App/SanchrApp.swift"),
                encoding: .utf8
            )
        }
    }

    func testTheUIIsReadyBeforeTheBackgroundWarmUp() throws {
        let text = try app
        let ready = try XCTUnwrap(text.range(of: "        sessionReady = true\n"))
        let warm = try XCTUnwrap(text.range(of: "Task { await warmSessionInBackground() }"))
        XCTAssertLessThan(ready.lowerBound, warm.lowerBound)
    }

    /// Each of these is a network round trip that used to gate the UI.
    func testTheNetworkWarmUpStepsLiveInTheBackground() throws {
        let text = try app
        let gateStart = try XCTUnwrap(text.range(of: "private func refreshSessionToken() async {"))
        let ready = try XCTUnwrap(text.range(of: "        sessionReady = true\n"))
        let gating = String(text[gateStart.upperBound..<ready.lowerBound])
        let warm = try XCTUnwrap(text.range(of: "private func warmSessionInBackground() async {"))
        let body = String(text[warm.upperBound...])
        for step in ["hasCompleteServerBundle", "checkAndReplenishPreKeys", "uploadPendingVoIPTokenIfNeeded",
                     "getSettings()", "getBlockedList()", "realtimeService.enterForeground()"] {
            XCTAssertFalse(gating.contains(step), "\(step) must not gate the UI")
            XCTAssertTrue(body.contains(step), "\(step) must still run")
        }
    }

    /// The reinstall profile restore decides onboarding, so it stays ahead.
    func testTheProfileRestoreStillGatesOnboarding() throws {
        let text = try app
        let restore = try XCTUnwrap(text.range(of: "let restored = await container.messageRepository.resolveOwnProfile()"))
        let ready = try XCTUnwrap(text.range(of: "        sessionReady = true\n"))
        XCTAssertLessThan(restore.lowerBound, ready.lowerBound)
    }
}
