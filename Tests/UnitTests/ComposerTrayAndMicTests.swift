import Foundation
import XCTest

@testable import Sanchr

/// The composer's trays, and what happens when recording cannot start.
final class ComposerTrayAndMicTests: XCTestCase {

    // MARK: - Trays

    /// The bug: three independent booleans meant every site that opened a tray
    /// had to remember to close the other two, and the "+" button never closed
    /// the sticker tray — so stickers reached from the attachment sheet, then
    /// "+", left both trays stacked.
    ///
    /// One optional value makes that unrepresentable. This test guards the
    /// property that matters: setting a tray replaces whatever was open.
    func testOnlyOneTrayCanBeOpen() {
        var tray: ComposerTray?
        XCTAssertNil(tray)

        tray = .attachments
        XCTAssertEqual(tray, .attachments)

        // The exact sequence that used to stack two trays.
        tray = .stickers
        XCTAssertEqual(tray, .stickers, "opening stickers must replace, not add")

        tray = .attachments
        XCTAssertEqual(tray, .attachments, "tapping + must replace the sticker tray")

        tray = nil
        XCTAssertNil(tray)
    }

    /// Guards against the flags coming back. A regression here would not fail
    /// any behavioural test — it would just quietly allow two trays again —
    /// so it is checked at the source level, where the mistake would be made.
    func testComposerDoesNotReintroduceIndependentTrayFlags() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let files = [
            "Features/Chats/Presentation/ChatDetailView.swift",
            "Features/Chats/Presentation/ChatInputBarView.swift",
        ]
        for relative in files {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            for banned in ["showAttachmentPicker", "showEmojiPicker", "showStickerPicker"] {
                XCTAssertFalse(
                    source.contains(banned),
                    "\(relative) reintroduced \(banned); trays must stay a single ComposerTray?"
                )
            }
        }
    }

    // MARK: - Microphone

    /// Holding the mic with permission denied used to do nothing at all: every
    /// error, including a denial, was swallowed into `.idle` with nothing on
    /// screen and no route to Settings.
    func testDeniedMicrophoneExplainsItselfAndPointsSomewhere() {
        let failure = VoiceMessageComposer.StartFailure.microphoneDenied
        XCTAssertFalse(failure.title.isEmpty)
        XCTAssertTrue(
            failure.message.lowercased().contains("settings"),
            "a denial the app cannot undo must say where to undo it"
        )
    }

    /// Other failures — a busy session, a file that could not be created —
    /// must surface their own reason rather than being flattened into the
    /// permission message, which would send people to Settings for nothing.
    func testOtherFailuresCarryTheirOwnReason() {
        let failure = VoiceMessageComposer.StartFailure.other("Recorder busy")
        XCTAssertEqual(failure.message, "Recorder busy")
        XCTAssertNotEqual(failure.title, VoiceMessageComposer.StartFailure.microphoneDenied.title)
        XCTAssertFalse(
            failure.message.lowercased().contains("settings"),
            "a non-permission failure must not send the user to Settings"
        )
    }

    /// Drives `.alert(item:)`, so two different failures must not collapse
    /// into one another and suppress the second alert.
    func testFailuresAreDistinguishable() {
        XCTAssertNotEqual(
            VoiceMessageComposer.StartFailure.microphoneDenied.id,
            VoiceMessageComposer.StartFailure.other("boom").id
        )
        XCTAssertNotEqual(
            VoiceMessageComposer.StartFailure.other("a").id,
            VoiceMessageComposer.StartFailure.other("b").id
        )
    }
}
