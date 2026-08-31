import Foundation
import XCTest

@testable import Sanchr

/// The composer's height as you start typing.
@MainActor
final class ComposerRowHeightTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The emoji button is an 18pt glyph, taller than a line of message text,
    /// and it leaves the row the moment there is something to send — so the
    /// field shrank by six points as soon as you typed, and the placeholder
    /// state was a different height from every state after it.
    ///
    /// Held by a hidden copy of the button rather than a measured constant.
    /// Two attempts at a number — the font's line height, then the rendered
    /// glyph's — each left a point of shrink, because what has to match is
    /// what SwiftUI lays out, not what the metrics say.
    func testTheRowReservesTheEmojiButtonsHeight() throws {
        let body = code(try source("Features/Chats/Presentation/ChatInputBarView.swift"))
        XCTAssertTrue(body.contains("Self.composerRowSpacer"))
        XCTAssertTrue(
            body.contains(".hidden()"),
            "hidden keeps the layout size; that is what makes the heights equal"
        )
        XCTAssertTrue(
            body.contains(".frame(width: 0)"),
            "and zero width keeps it from taking room beside the text"
        )
    }

    /// The spacer must never be announced — it is layout, not content.
    func testTheSpacerIsInvisibleToVoiceOver() throws {
        let body = code(try source("Features/Chats/Presentation/ChatInputBarView.swift"))
        let spacer = try XCTUnwrap(body.range(of: "static var composerRowSpacer"))
        let after = String(body[spacer.lowerBound...].prefix(400))
        XCTAssertTrue(after.contains(".accessibilityHidden(true)"))
    }
}
