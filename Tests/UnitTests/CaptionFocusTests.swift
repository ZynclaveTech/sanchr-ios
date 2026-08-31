import Foundation
import XCTest

@testable import Sanchr

/// Whether the caption field takes focus when the preview opens.
final class CaptionFocusTests: XCTestCase {

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

    private var caption: String {
        get throws { try source("Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift") }
    }

    /// The screen exists to show what is about to be sent, and the keyboard
    /// covers most of it. A caption is the exception rather than the rule, so
    /// it is asked for rather than assumed.
    func testThePreviewDoesNotOpenTheKeyboard() throws {
        XCTAssertFalse(
            try code(caption).contains("captionFocused = true"),
            "nothing should focus the field; tapping it is how it opens"
        )
    }

    /// A multi-line field has no Return key, so there has to be a way back to
    /// the picture once the caption has been tapped.
    func testTheKeyboardStillHasAWayOut() throws {
        let body = code(try caption)
        XCTAssertTrue(
            body.contains(".onTapGesture { captionFocused = false }"),
            "tapping the media closes it"
        )
        XCTAssertTrue(
            body.contains("Button(\"Done\") { captionFocused = false }"),
            "and so does Done, for anyone who does not think to tap the photo"
        )
    }
}
