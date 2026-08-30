import Foundation
import XCTest

@testable import Sanchr

/// "Enter sends message" is a user setting, on by default, and it did nothing.
/// It hung off `.onSubmit`, which a multiline `TextField(axis: .vertical)`
/// never fires — the Return key inserts a line break instead.
///
/// The inserted newline is now the signal, which puts the whole decision in a
/// pure function where the awkward cases can actually be pinned down.
final class EnterToSendTests: XCTestCase {

    func testReturnAtTheEndSends() {
        XCTAssertEqual(
            EnterToSend.submission(previous: "on my way", current: "on my way\n", enabled: true),
            "on my way"
        )
    }

    func testTheSettingIsHonoured() {
        XCTAssertNil(
            EnterToSend.submission(previous: "hello", current: "hello\n", enabled: false),
            "with the setting off, Return must insert a line break instead"
        )
    }

    /// The case that makes newline-watching safe. A paste changes many
    /// characters at once, so it must type rather than fire a send — otherwise
    /// pasting a copied paragraph would send it half-composed.
    func testPastingTextEndingInANewlineDoesNotSend() {
        XCTAssertNil(
            EnterToSend.submission(
                previous: "",
                current: "a whole pasted paragraph\n",
                enabled: true
            )
        )
    }

    /// Return pressed in the middle of a message is a line break, not a send.
    func testANewlineInTheMiddleDoesNotSend() {
        XCTAssertNil(
            EnterToSend.submission(previous: "line one two", current: "line one\n two", enabled: true)
        )
    }

    /// Return on an empty composer must do nothing at all — not send, and not
    /// leave a stray blank line behind either.
    func testReturnOnAnEmptyComposerDoesNothing() {
        XCTAssertNil(EnterToSend.submission(previous: "", current: "\n", enabled: true))
        XCTAssertNil(EnterToSend.submission(previous: "   ", current: "   \n", enabled: true))
    }

    /// A deliberate multi-line message: the second Return still sends what has
    /// been written, including the line break the user typed on purpose.
    func testASecondReturnSendsTheWholeMultilineMessage() {
        let body = EnterToSend.submission(
            previous: "first line\nsecond line",
            current: "first line\nsecond line\n",
            enabled: true
        )
        XCTAssertEqual(body, "first line\nsecond line")
    }

    /// Trailing spaces before the Return are trimmed, so a message does not go
    /// out with whatever whitespace happened to be sitting at the end.
    func testTrailingWhitespaceIsTrimmedFromWhatIsSent() {
        XCTAssertEqual(
            EnterToSend.submission(previous: "done   ", current: "done   \n", enabled: true),
            "done"
        )
    }

    /// Deleting text must never look like a send.
    func testDeletingDoesNotSend() {
        XCTAssertNil(EnterToSend.submission(previous: "hello\n", current: "hello", enabled: true))
        XCTAssertNil(EnterToSend.submission(previous: "hello", current: "hell", enabled: true))
    }

    /// Two newlines arriving at once is not a single keypress.
    func testTwoNewlinesAtOnceDoesNotSend() {
        XCTAssertNil(EnterToSend.submission(previous: "hi", current: "hi\n\n", enabled: true))
    }

    /// No change at all is not a send. `onChange` can fire for reasons other
    /// than typing.
    func testAnUnchangedValueDoesNotSend() {
        XCTAssertNil(EnterToSend.submission(previous: "hello", current: "hello", enabled: true))
    }
}
