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
}
