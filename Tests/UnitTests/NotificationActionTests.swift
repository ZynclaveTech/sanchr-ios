import Foundation
import XCTest

@testable import Sanchr

/// The two notification actions that carry a side effect, not a
/// destination: inline reply text and Decline. Both were parsed and then
/// dropped — the router only navigates.
final class NotificationActionTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testDeclineIsAnActionOfItsOwn() {
        XCTAssertNotEqual(NotificationAction.declineCall(callId: "c"), .none)
    }

    /// The reply is sent inside the notification response handler, where the
    /// system keeps the process alive, not deferred to a scene that may not
    /// exist.
    func testAnInlineReplyIsSentInTheResponseHandler() throws {
        let push = try source("Platform/Notifications/PushManager.swift")
        let handler = try XCTUnwrap(push.range(of: "didReceive response: UNNotificationResponse"))
        let body = String(push[handler.upperBound...].prefix(1500))
        XCTAssertTrue(body.contains("await onInlineReply?(conversationId, body)"))
        XCTAssertTrue(body.contains("await onDeclineCall?(callId)"))
        XCTAssertFalse(body.contains("pendingAction = action\n\n"), "reply and decline must not also be routed")
    }

    func testTheAppWiresBothHooks() throws {
        let app = try source("App/SanchrApp.swift")
        XCTAssertTrue(app.contains("pushManager.onInlineReply = "))
        XCTAssertTrue(app.contains("messageSender.sendText(text, to: conversationId)"))
        XCTAssertTrue(app.contains("pushManager.onDeclineCall = "))
        XCTAssertTrue(app.contains("callManager.declineCall(fromNotificationFor: callId)"))
    }

    func testTheRouterNoLongerNavigatesOnAReply() throws {
        let router = try source("App/AppRouter.swift")
        XCTAssertFalse(router.contains("case .replyToMessage(let conversationId, _)"))
    }
}
