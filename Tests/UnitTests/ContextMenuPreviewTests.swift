import Foundation
import XCTest

@testable import Sanchr

/// What the transcript shows while its context menu is open.
///
/// Long-pressing a message must keep showing that message. A custom
/// `previewProvider` REPLACES the lifted cell snapshot, so returning anything
/// other than the message removes the message — which is what happened: a row
/// of six emoji appeared where the bubble should have been.
///
/// Signal takes the same position from the other direction. Its
/// `ContextMenuTargetedPreview(view:alignment:accessoryViews:)` makes the
/// message view the preview and attaches the reaction bar as a separate
/// accessory, rather than putting the bar in the preview's place.
final class ContextMenuPreviewTests: XCTestCase {

    private var source: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "Features/Chats/Presentation/MessageCollectionViewController.swift"
                    ),
                encoding: .utf8
            )
        }
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The regression: the message has to remain visible, which means letting
    /// UIKit lift the real cell.
    func testTheMessageIsWhatGetsLifted() throws {
        XCTAssertTrue(
            try code(source).contains("previewProvider: nil"),
            "a custom preview replaces the message; the message must be the preview"
        )
    }

    /// The emoji row is gone entirely rather than moved somewhere else — with
    /// a native context menu there is nowhere above the preview to put it.
    func testTheDecorativeEmojiRowIsGone() throws {
        let body = try code(source)
        XCTAssertFalse(
            body.contains("makeReactionPreview"),
            "the emoji preview should be removed, not merely unused"
        )
    }

    /// Reacting still has to be reachable — it is the thing the emoji row was
    /// pretending to offer.
    func testReactingIsStillOfferedAndWiredToSomething() throws {
        let body = try source
        XCTAssertTrue(body.contains("UIMenu(title: \"React\""))
        XCTAssertTrue(
            body.contains("self?.onReactToMessage?(emoji, message.id)"),
            "the React submenu must call something, unlike the buttons it replaces"
        )
    }
}
