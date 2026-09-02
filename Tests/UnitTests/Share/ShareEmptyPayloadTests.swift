import Foundation
import XCTest

/// `ShareSendDispatcher` documents that no units means immediate success
/// for every recipient. The coordinator in the extension is the one place
/// that knows a payload flattened to nothing, so it must refuse there.
/// The extension binary is not @testable from this target; this pins the
/// source.
final class ShareEmptyPayloadTests: XCTestCase {
    func testTheCoordinatorRefusesAPayloadWithNoUnits() throws {
        let coordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SanchrShareExtension/Send/ShareSendCoordinator.swift"),
            encoding: .utf8
        )
        let flatten = try XCTUnwrap(coordinator.range(of: "let units = Self.flatten(payload: payload, caption: caption)"))
        let after = String(coordinator[flatten.upperBound...].prefix(700))
        XCTAssertTrue(after.contains("guard !units.isEmpty else {"))
        XCTAssertTrue(after.contains(".failure(\"Nothing to share.\")"))
        XCTAssertTrue(after.range(of: "guard !units.isEmpty")!.lowerBound < after.range(of: "ShareSendDispatcher(sender:")!.lowerBound,
                      "the guard must run before anything is dispatched")
    }
}
