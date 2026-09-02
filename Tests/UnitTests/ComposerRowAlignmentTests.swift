import Foundation
import XCTest

@testable import Sanchr

/// The composer row is bottom-aligned so the controls follow the last line
/// of a growing field. A single line is taller than the controls, so flush
/// bottoms left the plus and the mic sitting low of the field's centre.
@MainActor
final class ComposerRowAlignmentTests: XCTestCase {

    func testBothSideControlsAreLiftedOntoTheFieldsCentre() throws {
        let bar = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Chats/Presentation/ChatInputBarView.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(bar.components(separatedBy: ".padding(.bottom, Self.sideControlBottomInset)").count - 1, 2,
                       "the plus button and the trailing control both take the inset")
        XCTAssertEqual(ChatInputBarView.sideControlBottomInset, 2.75, accuracy: 0.01)
    }
}
