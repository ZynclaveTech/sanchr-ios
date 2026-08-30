import Foundation
import XCTest

@testable import Sanchr

/// The composer's controls are icon-only, so a missing label leaves VoiceOver
/// with nothing but an SF Symbol name on the app's primary surface. There were
/// none at all.
///
/// Checked at the source level: SwiftUI accessibility modifiers are not
/// readable from a unit test, and a missing label fails nothing at runtime —
/// it just silently degrades for the people who depend on it most.
final class ComposerAccessibilityTests: XCTestCase {

    private var composerSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: root.appendingPathComponent(
                    "Features/Chats/Presentation/ChatInputBarView.swift"
                ),
                encoding: .utf8
            )
        }
    }

    func testEveryComposerControlIsLabelled() throws {
        let source = try composerSource
        for label in ["\"Send\"", "\"Attachments\"", "\"Emoji\"", "\"Cancel reply\"", "\"Message\""] {
            XCTAssertTrue(
                source.contains(".accessibilityLabel(") && source.contains(label),
                "the composer is missing an accessibility label for \(label)"
            )
        }
    }

    /// Two controls change glyph with state. A fixed label would describe the
    /// wrong action half the time — "Emoji" while showing a keyboard, or
    /// "Attachments" while showing a close button.
    func testStatefulControlsRelabelWithTheirGlyph() throws {
        let source = try composerSource
        XCTAssertTrue(
            source.contains("\"Close attachments\""),
            "the + button turns into a close button and must say so"
        )
        XCTAssertTrue(
            source.contains("\"Show keyboard\""),
            "the emoji button turns into a keyboard button and must say so"
        )
    }

    /// The send button had no disabled state at all, so `isSending` guarded
    /// nothing on screen.
    func testSendIsDisabledWhileSending() throws {
        XCTAssertTrue(
            try composerSource.contains(".disabled(input.isSending)"),
            "send must be disabled while a send is in flight"
        )
    }
}
