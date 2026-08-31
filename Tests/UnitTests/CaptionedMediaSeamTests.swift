import CoreGraphics
import Foundation
import XCTest

@testable import Sanchr

/// Media that shares its bubble with a caption.
///
/// The picture rounded its own bottom corners and sat 6pt above the text, so a
/// captioned message read as a photo and a separate slab of purple rather than
/// one bubble. The bubble already rounds the outside; the picture only has to
/// round the edges that are actually the outside.
final class CaptionedMediaSeamTests: XCTestCase {

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

    // MARK: - What counts as a caption

    func testCaptionedMediaMeetsItsText() {
        XCTAssertEqual(MessageBubble.mediaSpacing(hasCaption: true), 0)
    }

    func testUncaptionedMediaKeepsItsSpacing() {
        XCTAssertEqual(MessageBubble.mediaSpacing(hasCaption: false), 6)
    }

    /// A caption of spaces is not a caption. Treating it as one would square
    /// the corners and close the gap for a bubble with nothing under it.
    func testWhitespaceIsNotACaption() {
        XCTAssertFalse(MessageBubble.hasCaption("   \n  "))
        XCTAssertFalse(MessageBubble.hasCaption(""))
        XCTAssertFalse(MessageBubble.hasCaption(nil))
        XCTAssertTrue(MessageBubble.hasCaption("hello"))
    }

    // MARK: - The corners

    /// The same condition drives both, because a squared corner with a gap
    /// under it looks worse than either alone.
    func testTheCornersAndTheSpacingAgree() throws {
        let body = code(try source("Features/Chats/Presentation/MessageBubble.swift"))
        XCTAssertTrue(body.contains("squaresBottomCorners: Self.hasCaption(single.caption)"))
        XCTAssertTrue(
            body.contains("spacing: Self.mediaSpacing(hasCaption: Self.hasCaption(attachment.first?.caption))"),
            "one condition, so they cannot disagree"
        )
    }

    /// Only the bottom. The top of the picture is still the top of the bubble.
    func testOnlyTheBottomCornersAreSquared() throws {
        let body = code(try source("Features/Chats/Presentation/MediaBubbleImage.swift"))
        XCTAssertTrue(body.contains("topLeadingRadius: cornerRadius"))
        XCTAssertTrue(body.contains("topTrailingRadius: cornerRadius"))
        XCTAssertTrue(body.contains("bottomLeadingRadius: squaresBottomCorners ? 0 : cornerRadius"))
        XCTAssertTrue(body.contains("bottomTrailingRadius: squaresBottomCorners ? 0 : cornerRadius"))
    }

    /// The gap belongs to the text, not to the stack.
    ///
    /// Closing the stack's gap removed the seam and also removed the room the
    /// words had: the first line came to rest directly on the photo's bottom
    /// edge. A stack gap would bring the seam back, so the inset is padding on
    /// the caption instead.
    func testTheCaptionHasRoomAboveItWithoutReopeningTheSeam() throws {
        let body = code(try source("Features/Chats/Presentation/MessageBubble.swift"))
        XCTAssertTrue(
            body.contains(".padding(.top, SanchrSpacing.bubbleVPadding)"),
            "the words need somewhere to sit"
        )
        XCTAssertEqual(
            MessageBubble.mediaSpacing(hasCaption: true), 0,
            "and the stack must still not add one, or the seam returns"
        )
    }
}
