import Foundation
import XCTest

@testable import Sanchr

/// A contact or location send must appear in the transcript at once, like
/// text does. Both used to call the sender and stop, so the message only
/// showed up on the next open.
final class InlineSendTests: XCTestCase {

    func testContactAndLocationSendsAreOptimistic() throws {
        let send = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Chats/Presentation/ChatDetailViewModel+Send.swift"),
            encoding: .utf8
        )
        for content in ["content: .contact(name: stripped.displayName, phoneNumber: phoneNumber)",
                        "content: .location(latitude: payload.latitude, longitude: payload.longitude)"] {
            XCTAssertTrue(send.contains(content), content)
        }
        let helper = try XCTUnwrap(send.range(of: "private func sendInlineMessage("))
        let body = String(send[helper.upperBound...].prefix(2200))
        XCTAssertTrue(body.contains("appendMessageToSections(optimisticMessage)"))
        XCTAssertTrue(body.contains("replaceMessage(id: optimisticMessage.id, with: confirmed)"))
        XCTAssertTrue(body.contains("$0.status = .failed"))
        XCTAssertFalse(send.contains("_ = try await context.messageSender.sendContact("), "the bare send is gone")
    }
}
