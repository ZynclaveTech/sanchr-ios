import Foundation
import SanchrShared
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

    // MARK: - Sections

    private func conversation(_ id: String, _ name: String, group: Bool = false) -> Conversation {
        Conversation(
            id: id,
            participants: [
                User(id: "u-\(id)", phoneNumber: "+9155500\(id)", displayName: name,
                     isVerified: false, status: .offline)
            ],
            unreadCount: 0, isPinned: false, isMuted: false, isArchived: false,
            type: group ? .group : .oneToOne,
            createdAt: Date(), updatedAt: Date()
        )
    }

    /// Recents first, then contacts, then groups — Signal's order, and the
    /// one that puts the likely destination at the top instead of behind a
    /// scroll through every conversation.
    func testDestinationsAreGroupedRecentsFirst() {
        let all = (1...8).map { conversation("\($0)", "Name \($0)", group: $0 > 6) }
        let sections = MessageForwardDestinationPicker.sections(
            for: all, searching: false, recentLimit: 3
        )
        XCTAssertEqual(sections.map { $0.title }, ["Recent", "Contacts", "Groups"])
        XCTAssertEqual(sections[0].items.count, 3)
    }

    /// A conversation appears once. Being recent should not also list it under
    /// contacts.
    func testARecentConversationIsNotListedTwice() {
        let all = (1...5).map { conversation("\($0)", "Name \($0)") }
        let sections = MessageForwardDestinationPicker.sections(
            for: all, searching: false, recentLimit: 2
        )
        let ids = sections.flatMap { $0.items.map { $0.id } }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Sections shorten the path to a likely destination. Once a name has been
    /// typed, the likely destination is whatever matches it.
    func testSearchingCollapsesToOneList() {
        let all = (1...5).map { conversation("\($0)", "Name \($0)") }
        let sections = MessageForwardDestinationPicker.sections(for: all, searching: true)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
    }

    func testAnEmptySectionIsNotShown() {
        let all = [conversation("1", "Solo")]
        let sections = MessageForwardDestinationPicker.sections(
            for: all, searching: false, recentLimit: 5
        )
        XCTAssertEqual(sections.map { $0.title }, ["Recent"])
    }
}
