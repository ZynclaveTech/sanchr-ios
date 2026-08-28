import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// The media viewer pages one *attachment* at a time, so an album of four is
/// four pages. Previously a page was one message, which collapsed an album to
/// its first photo with no way to reach the rest.
@MainActor
final class GalleryAlbumPagingTests: XCTestCase {

    private func attachment(_ id: String, mime: String = "image/jpeg") -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://\(id)")!,
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: mime, sizeBytes: 1, thumbnailURL: nil
        )
    }

    private func message(
        _ id: String,
        _ content: Message.MessageContent,
        secondsAgo: Int
    ) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 - TimeInterval(secondsAgo)),
            content: content,
            status: .sent,
            isOutgoing: false
        )
    }

    private func viewModel(_ messages: [Message]) -> ChatDetailViewModel {
        let vm = ChatDetailViewModel()
        vm.messages = messages
        return vm
    }

    // MARK: - Page expansion

    func testAnAlbumBecomesOnePagePerAttachment() {
        let album = message(
            "album",
            .image(.init([attachment("a"), attachment("b"), attachment("c")])),
            secondsAgo: 0
        )
        let seed = viewModel([album]).galleryItems(forTappedMessageId: "album")

        XCTAssertEqual(seed?.items.count, 3, "an album must not collapse to one page")
        XCTAssertEqual(seed?.items.map(\.attachmentIndex), [0, 1, 2])
    }

    /// Page ids must be unique or the pager collapses entries.
    func testPageIdsAreUnique() {
        let album = message(
            "album", .image(.init((0..<5).map { attachment("a\($0)") })), secondsAgo: 0
        )
        let seed = viewModel([album]).galleryItems(forTappedMessageId: "album")
        XCTAssertEqual(Set(seed?.items.map(\.id) ?? []).count, 5)
    }

    /// A single attachment keeps the bare message id, so nothing that referred
    /// to a page by message id breaks.
    func testSingleAttachmentPageKeepsTheMessageId() {
        let single = message("solo", .image(.init(attachment("x"))), secondsAgo: 0)
        let seed = viewModel([single]).galleryItems(forTappedMessageId: "solo")
        XCTAssertEqual(seed?.items.first?.id, "solo")
    }

    // MARK: - Opening position

    /// The whole point of carrying the index: tapping the third tile opens the
    /// third photo, not the first.
    func testOpensOnTheTappedTile() {
        let album = message(
            "album",
            .image(.init([attachment("a"), attachment("b"), attachment("c")])),
            secondsAgo: 0
        )
        let seed = viewModel([album])
            .galleryItems(forTappedMessageId: "album", attachmentIndex: 2)

        XCTAssertEqual(seed?.initialIndex, 2)
        XCTAssertEqual(seed?.items[seed!.initialIndex].attachmentIndex, 2)
    }

    /// A stale index must still open the message rather than failing outright.
    func testOutOfRangeIndexFallsBackToTheMessagesFirstPage() {
        let album = message("album", .image(.init([attachment("a"), attachment("b")])), secondsAgo: 0)
        let seed = viewModel([album])
            .galleryItems(forTappedMessageId: "album", attachmentIndex: 99)

        XCTAssertNotNil(seed)
        XCTAssertEqual(seed?.initialIndex, 0)
    }

    /// Pages from other messages must not shift the opening position.
    func testOpensCorrectlyAmongOtherMedia() {
        let older = message("older", .image(.init(attachment("o"))), secondsAgo: 300)
        let album = message(
            "album",
            .image(.init([attachment("a"), attachment("b"), attachment("c")])),
            secondsAgo: 100
        )
        let newer = message("newer", .video(.init(attachment("v", mime: "video/mp4"))), secondsAgo: 0)

        let seed = viewModel([newer, older, album])
            .galleryItems(forTappedMessageId: "album", attachmentIndex: 1)

        // Chronological: older, album[0..2], newer
        XCTAssertEqual(seed?.items.count, 5)
        XCTAssertEqual(seed?.initialIndex, 2, "older + album[0] precede album[1]")
        XCTAssertEqual(seed?.items[2].messageId, "album")
        XCTAssertEqual(seed?.items[2].attachmentIndex, 1)
    }

    // MARK: - Page content

    /// Each page must resolve its own attachment, or every page of an album
    /// would render the same photo.
    func testEachPageResolvesItsOwnAttachment() {
        let album = message(
            "album",
            .image(.init([attachment("a"), attachment("b"), attachment("c")])),
            secondsAgo: 0
        )
        let seed = viewModel([album]).galleryItems(forTappedMessageId: "album")

        XCTAssertEqual(
            seed?.items.compactMap { $0.attachment?.url.absoluteString },
            ["sanchr-media://a", "sanchr-media://b", "sanchr-media://c"]
        )
    }

    func testVideoAlbumPagesAreTypedAsVideo() {
        let album = message(
            "clips",
            .video(.init([attachment("v1", mime: "video/mp4"), attachment("v2", mime: "video/mp4")])),
            secondsAgo: 0
        )
        let seed = viewModel([album]).galleryItems(forTappedMessageId: "clips")
        XCTAssertEqual(seed?.items.map(\.kind), [.video, .video])
    }

    func testNonMediaMessagesProduceNoPages() {
        let seed = viewModel([
            message("text", .text("hello"), secondsAgo: 10),
            message("img", .image(.init(attachment("i"))), secondsAgo: 0),
        ]).galleryItems(forTappedMessageId: "img")

        XCTAssertEqual(seed?.items.count, 1)
    }

    func testTappingAMessageWithNoMediaReturnsNothing() {
        let seed = viewModel([message("text", .text("hello"), secondsAgo: 0)])
            .galleryItems(forTappedMessageId: "text")
        XCTAssertNil(seed)
    }
}
