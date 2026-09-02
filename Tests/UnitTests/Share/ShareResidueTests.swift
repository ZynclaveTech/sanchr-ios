import Foundation
import XCTest

/// Files the share extension copies into the App Group cache are the sent
/// messages' local media — but when nothing was sent they were never
/// deleted. The extension is not @testable from here; this pins the source.
final class ShareResidueTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testACancelledShareRemovesItsCopies() throws {
        let root = try source("SanchrShareExtension/UI/ShareRootView.swift")
        XCTAssertEqual(root.components(separatedBy: "onCancel: { payload.removeFiles(); onCancel() }").count - 1, 2,
                       "both the picker and the composer cancel must remove the copies")
    }

    func testASendThatReachedNoOneRemovesItsCopies() throws {
        let coordinator = try source("SanchrShareExtension/Send/ShareSendCoordinator.swift")
        XCTAssertTrue(coordinator.contains("if !anySent.value {\n            payload.removeFiles()"))
        XCTAssertTrue(coordinator.contains("if case .success = mapped { anySent.set() }"))
    }

    func testTheNoUnitsPathRemovesItsCopiesToo() throws {
        let coordinator = try source("SanchrShareExtension/Send/ShareSendCoordinator.swift")
        let guardRange = try XCTUnwrap(coordinator.range(of: "guard !units.isEmpty else {"))
        XCTAssertTrue(String(coordinator[guardRange.upperBound...].prefix(200)).contains("payload.removeFiles()"))
    }
}
