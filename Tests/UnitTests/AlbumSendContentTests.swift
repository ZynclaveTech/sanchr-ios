import XCTest
import SanchrShared

@testable import Sanchr

/// Wire content for a multi-attachment send. The receiver routes on the
/// content type string and renders from the attachment list, so both have to
/// come out right or an album arrives as the wrong kind of message — or as one
/// photo with the rest silently gone.
final class AlbumSendContentTests: XCTestCase {

    private func attachment(_ id: String, mime: String = "image/jpeg") -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://\(id)")!,
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: mime, sizeBytes: 1, thumbnailURL: nil
        )
    }

    func testAlbumCarriesEveryAttachmentInOrder() {
        let content = MessageSender.contentForAlbum(
            [attachment("a"), attachment("b"), attachment("c")]
        )
        guard case .image(let media) = content else { return XCTFail("expected .image") }
        XCTAssertEqual(media.count, 3)
        XCTAssertEqual(media.items.map(\.url.absoluteString),
                       ["sanchr-media://a", "sanchr-media://b", "sanchr-media://c"])
    }

    /// The album is typed by its first member, which is what the receiver's
    /// routing keys on.
    func testAlbumIsTypedByItsFirstMember() {
        if case .video = MessageSender.contentForAlbum([attachment("v", mime: "video/mp4")]) {} else {
            XCTFail("a video-led album must be .video")
        }
        if case .image = MessageSender.contentForAlbum([attachment("i")]) {} else {
            XCTFail("an image-led album must be .image")
        }
        if case .document = MessageSender.contentForAlbum(
            [attachment("d", mime: "application/pdf")]
        ) {} else {
            XCTFail("a document-led album must be .document")
        }
    }

    /// A mixed album keeps every member; only the routing type comes from the
    /// first. Dropping the others here would be silent data loss.
    func testMixedAlbumKeepsEveryMember() {
        let content = MessageSender.contentForAlbum([
            attachment("photo"),
            attachment("clip", mime: "video/mp4"),
        ])
        guard case .image(let media) = content else { return XCTFail("expected .image") }
        XCTAssertEqual(media.count, 2)
        XCTAssertEqual(media.items[1].mimeType, "video/mp4")
    }

    func testContentTypeStringMatchesTheMime() {
        XCTAssertEqual(MessageSender.contentTypeString(for: "image/heic"), "image")
        XCTAssertEqual(MessageSender.contentTypeString(for: "video/quicktime"), "video")
        XCTAssertEqual(MessageSender.contentTypeString(for: "audio/m4a"), "audio")
        XCTAssertEqual(MessageSender.contentTypeString(for: "application/pdf"), "document")
        XCTAssertEqual(MessageSender.contentTypeString(for: "weird/thing"), "document",
                       "an unknown type must still route somewhere")
    }

    /// An empty list cannot happen from the review screen, but must not trap.
    func testEmptyAlbumDoesNotCrash() {
        if case .image(let media) = MessageSender.contentForAlbum([]) {
            XCTAssertTrue(media.isEmpty)
        } else {
            XCTFail("expected .image for an empty album")
        }
    }

    /// The album round-trips through the wire encoding it will actually take.
    func testAlbumSurvivesTheWireEncoding() throws {
        let content = MessageSender.contentForAlbum([attachment("1"), attachment("2")])
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(Message.MessageContent.self, from: data)
        XCTAssertEqual(decoded, content)
    }
}
