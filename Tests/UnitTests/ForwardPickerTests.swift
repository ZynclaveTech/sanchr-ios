import Foundation
import XCTest

@testable import Sanchr

/// Choosing where a message goes.
@MainActor
final class ForwardPickerTests: XCTestCase {

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

    private var picker: String {
        get throws { try source("Features/Chats/Presentation/MessageForwardDestinationPicker.swift") }
    }

    // MARK: - Confirming

    /// A tap used to forward immediately. Every row was one mis-tap away from
    /// sending a private message to the wrong person, and a forward cannot be
    /// recalled.
    func testTappingARowSelectsRatherThanSends() throws {
        let body = code(try picker)
        XCTAssertTrue(
            body.contains("toggle(conversation.id)"),
            "the row picks a destination; sending is a separate act"
        )
        XCTAssertFalse(
            body.contains("onConversationPicked(conversation.id"),
            "sending straight from the row is the bug this guards"
        )
    }

    // MARK: - Naming the destinations

    /// The names matter more than the count: what is being confirmed is who
    /// will see a message they were not sent.
    func testTheFooterNamesWhoIsBeingSentTo() {
        let names = MessageForwardDestinationPicker.namesText
        XCTAssertEqual(names(["Ravi"]), "Ravi")
        XCTAssertEqual(names(["Ravi", "Meera"]), "Ravi and Meera")
        XCTAssertEqual(names(["Ravi", "Meera", "Arjun"]), "Ravi, Meera and 1 other")
        XCTAssertEqual(
            names(["Ravi", "Meera", "Arjun", "Sana"]),
            "Ravi, Meera and 2 others"
        )
    }

    func testNoDestinationsNamesNobody() {
        XCTAssertEqual(MessageForwardDestinationPicker.namesText(for: []), "")
    }

    // MARK: - The gallery

    /// The transcript's context menu offered Forward and the media viewer did
    /// not, so opening a photo took the action away.
    func testTheMediaViewerCanForward() throws {
        let gallery = code(
            try source("Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift")
        )
        XCTAssertTrue(gallery.contains("Label(\"Forward\""))
        XCTAssertTrue(
            gallery.contains("var onForward: ((Message) -> Void)?"),
            "optional, since the gallery also opens where there is nothing to forward from"
        )
    }
}
