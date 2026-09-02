import Foundation
import XCTest

@testable import Sanchr

/// A wrong Registration Lock PIN shakes the entry and lets the user try
/// again. `PINEntryView.triggerError` existed for exactly this and nothing
/// called it: a wrong PIN closed the screen and put up an alert instead.
final class PINRejectionTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testTheEntryShakesWhenItsTriggerChanges() throws {
        let entry = try source("Features/Settings/Presentation/PINEntryView.swift")
        XCTAssertTrue(entry.contains("var errorTrigger: Int = 0"))
        XCTAssertTrue(entry.contains(".onChange(of: errorTrigger) { _, _ in triggerError() }"))
    }

    func testAWrongDisablePINKeepsTheEntryOnScreen() throws {
        let view = try source("Features/Settings/Presentation/RegistrationLockView.swift")
        let disable = try XCTUnwrap(view.range(of: "private func disableLock(pin: String) async {"))
        let body = String(view[disable.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("pinErrorTrigger += 1"))
        XCTAssertFalse(body.contains("errorMessage = \"Incorrect PIN. Please try again.\""))
        XCTAssertTrue(view.contains("errorTrigger: pinErrorTrigger"))
    }
}
