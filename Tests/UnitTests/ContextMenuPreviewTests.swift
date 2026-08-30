import Foundation
import XCTest

@testable import Sanchr

/// What the transcript shows while its context menu is open.
///
/// Long-pressing a message must keep showing that message. It once did the
/// opposite: a custom `previewProvider` REPLACED the lifted cell, so a row of
/// six emoji appeared where the bubble should have been.
///
/// That was fixed by handing UIKit no preview at all, which pinned the menu to
/// what UIKit was willing to lift. The menu is ours now — the reaction bar sits
/// above the message, where `UIContextMenuInteraction` could never put it — so
/// the same property is upheld a different way: the overlay draws the cell's
/// own snapshot. Signal arrives here too, via
/// `ContextMenuTargetedPreview(view:alignment:accessoryViews:)`: the message is
/// the preview, and the bar is an accessory beside it rather than a thing in
/// its place.
final class ContextMenuPreviewTests: XCTestCase {

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private var source: String {
        get throws {
            try read("Features/Chats/Presentation/MessageCollectionViewController.swift")
        }
    }

    private var overlay: String {
        get throws {
            try read("Features/Chats/Presentation/ContextMenu/MessageContextMenuOverlay.swift")
        }
    }

    private var transcript: String {
        get throws {
            try read("Features/Chats/Presentation/ChatTranscriptView.swift")
        }
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The regression this file exists for: the message has to stay on screen
    /// while its menu is open.
    ///
    /// It used to be guaranteed by handing UIKit no preview so it lifted the
    /// real cell. The menu is ours now, so the guarantee moved: the overlay
    /// draws the cell's own snapshot. Same property, different mechanism.
    func testTheMessageIsDrawnInTheMenu() throws {
        let overlay = try self.overlay
        XCTAssertTrue(
            overlay.contains("Image(uiImage: presentation.snapshot)"),
            "the overlay must draw the message it was opened for"
        )
    }

    /// And the native menu is gone rather than left alongside it — two menus
    /// on one long press would be worse than either.
    func testTheNativeContextMenuIsGone() throws {
        let body = code(try source)
        XCTAssertFalse(
            body.contains("contextMenuConfigurationForItemAt"),
            "the native context menu should be removed, not left to compete"
        )
    }

    /// Reacting still has to be reachable — it is the thing the emoji row was
    /// pretending to offer.
    func testReactingIsStillOfferedAndWiredToSomething() throws {
        let overlay = try self.overlay
        XCTAssertTrue(overlay.contains("quickReactions"))
        XCTAssertTrue(
            overlay.contains("onReact(emoji)"),
            "the reaction bar must call something, unlike the empty buttons it replaces"
        )
    }

    /// The menu covers the whole screen, not just the transcript.
    ///
    /// It was first attached as `.overlay` on this view — which is one child of
    /// the chat screen's VStack, so the blur stopped at the transcript's edges.
    /// The header, the encryption banner and the composer stayed sharp on top
    /// of the menu, and the action list ran on underneath the composer.
    func testTheMenuIsPresentedAboveTheWholeScreen() throws {
        let body = code(try transcript)
        XCTAssertTrue(
            body.contains("contextMenuWindow.present("),
            "the menu needs its own window; a transcript overlay cannot cover the header or composer"
        )
        XCTAssertFalse(
            body.contains("MessageContextMenuOverlay(") && body.contains(".overlay {\n            if let contextPresentation"),
            "presenting it as an overlay of the transcript is the bug this guards"
        )
    }

    /// `sourceFrame` is measured in window coordinates, so the view drawing it
    /// has to be the window — as a transcript overlay the message was drawn
    /// offset by the height of everything above the transcript.
    func testTheMessageFrameAndTheMenuShareACoordinateSpace() throws {
        XCTAssertTrue(
            try code(source).contains("cell.convert(cell.bounds, to: window)"),
            "the frame is window-space, which is why the menu is presented in a window"
        )
    }

    /// `.position` expands the view it modifies to fill its parent, so the
    /// positioned stack became a full-screen layer over the backdrop and ate
    /// every tap meant to dismiss.
    func testTappingOutsideCanReachTheBackdrop() throws {
        let body = code(try overlay)
        XCTAssertFalse(
            body.contains(".position("),
            ".position fills the parent and swallows the backdrop's taps; offset from the top-left instead"
        )
        XCTAssertTrue(
            body.contains(".allowsHitTesting(false)"),
            "the lifted message must let a tap through to the backdrop rather than absorb it"
        )
    }

    /// The keyboard covers the menu, and dismissing it moves the cell the menu
    /// is positioned by — so it goes first, and the snapshot waits for it.
    func testTheKeyboardIsDismissedBeforeTheMessageIsSnapshotted() throws {
        let body = code(try source)
        XCTAssertTrue(body.contains("endEditing(true)"))
        XCTAssertTrue(
            body.contains("keyboardDidHideNotification"),
            "snapshotting before the keyboard finishes leaving captures a stale frame"
        )
        let dismiss = try XCTUnwrap(body.range(of: "endEditing(true)"))
        let snapshot = try XCTUnwrap(body.range(of: "UIGraphicsImageRenderer"))
        XCTAssertTrue(
            dismiss.lowerBound < snapshot.lowerBound,
            "the keyboard has to go before the frame is measured, not after"
        )
    }

    /// Whether to wait for the keyboard is decided from the keyboard's own
    /// notifications, not from `endEditing(true)`'s return value.
    ///
    /// That return value does not mean "there was a keyboard" — it can report
    /// `true` with nothing being edited. Reading it that way parked every long
    /// press waiting for a `keyboardDidHide` that would never be posted, and
    /// the menu stopped opening at all.
    func testKeyboardWaitIsNotDecidedByEndEditingsReturnValue() throws {
        let body = code(try source)
        XCTAssertFalse(
            body.contains("if view.window?.endEditing(true) == true"),
            "endEditing's result is not a report of whether a keyboard was up"
        )
        XCTAssertTrue(body.contains("keyboardWillShowNotification"))
        XCTAssertTrue(
            body.contains("guard isKeyboardVisible else"),
            "with no keyboard the menu must open immediately, not wait for one to leave"
        )
    }

    /// And a notification that never arrives must not be able to swallow the
    /// menu the way the previous version could.
    func testAMissedKeyboardNotificationCannotSwallowTheMenu() throws {
        let body = code(try source)
        XCTAssertTrue(
            body.contains("asyncAfter"),
            "the wait needs a deadline; a menu placed slightly off beats no menu"
        )
    }
}
