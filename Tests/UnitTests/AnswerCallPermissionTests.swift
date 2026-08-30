import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Answering a call had no permission check, while placing one validated
/// carefully. Someone who revoked microphone access could answer and sit in a
/// call they could not speak on, with nothing to explain the silence.
final class AnswerCallPermissionTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Checked at the source: the failure is a call that connects and stays
    /// silent, which no unit test observes and no crash reports.
    func testAnswerCallChecksTheMicrophone() throws {
        let manager = try source("Platform/Calls/CallManager.swift")
        let answerBody = try XCTUnwrap(
            manager.range(of: "func answerCall() async throws {").map {
                String(manager[$0.upperBound...].prefix(2500))
            }
        )
        XCTAssertTrue(
            answerBody.contains("recordPermission"),
            "answering must check microphone permission, as placing a call does"
        )
        XCTAssertTrue(
            answerBody.contains("callPermissionDenied"),
            "a denied microphone must fail the answer with a reason"
        )
    }

    /// The message has to name the way out. Once denied, the app cannot ask
    /// again — stating only the problem leaves the person stuck.
    func testThePermissionMessagePointsToSettings() {
        let message = AppError.callPermissionDenied.localizedDescription
        XCTAssertTrue(
            message.lowercased().contains("settings"),
            "a permission the app cannot re-request must say where to grant it"
        )
        XCTAssertTrue(message.lowercased().contains("microphone"))
    }

    /// Answering happens from CallKit's UI, often on the lock screen with the
    /// app not foreground, so the reason has to outlive the moment it failed.
    func testTheReasonSurvivesUntilTheAppIsOpened() throws {
        let manager = try source("Platform/Calls/CallManager.swift")
        XCTAssertTrue(
            manager.contains("var lastCallError: String?"),
            "the failure reason must persist past the failed answer"
        )
        let list = try source("Features/Calls/Presentation/CallsListView.swift")
        XCTAssertTrue(
            list.contains("lastCallError"),
            "something has to deliver it, or it is dead state like the ones this audit keeps finding"
        )
    }
}
