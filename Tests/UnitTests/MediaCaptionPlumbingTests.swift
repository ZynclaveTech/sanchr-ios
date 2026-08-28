import XCTest
import SanchrShared

@testable import Sanchr

/// Captions on media. They were collected, sent and stored from the start but
/// never rendered, so anything typed on the caption or review screen vanished
/// on arrival. These cover the plumbing that carries one to the bubble.
final class MediaCaptionPlumbingTests: XCTestCase {

    private func attachment(_ id: String, caption: String? = nil) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://\(id)")!,
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "image/jpeg", sizeBytes: 1, thumbnailURL: nil,
            caption: caption
        )
    }

    /// The album's caption reads from the first attachment, which is where the
    /// bubble draws it.
    func testAlbumCaptionReadsFromTheFirstAttachment() {
        let media = Message.MediaAttachments([
            attachment("a", caption: "at the beach"),
            attachment("b"),
        ])
        XCTAssertEqual(media.caption, "at the beach")
    }

    func testSettingTheAlbumCaptionLandsOnTheFirstAttachment() {
        var media = Message.MediaAttachments([attachment("a"), attachment("b")])
        media.caption = "sunset"
        XCTAssertEqual(media.items[0].caption, "sunset")
        XCTAssertNil(media.items[1].caption, "only the first carries it")
    }

    /// Setting a caption on an empty group must not trap.
    func testCaptionOnAnEmptyGroupIsSafe() {
        var media = Message.MediaAttachments([])
        media.caption = "nothing here"
        XCTAssertNil(media.caption)
    }

    /// A caption must survive the encoding the message actually takes, or it
    /// arrives empty however well the bubble renders.
    func testCaptionSurvivesTheWireEncoding() throws {
        let content = Message.MessageContent.image(
            .init([attachment("a", caption: "hello"), attachment("b")])
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(Message.MessageContent.self, from: data)

        guard case .image(let media) = decoded else { return XCTFail("expected .image") }
        XCTAssertEqual(media.caption, "hello")
        XCTAssertEqual(media.count, 2, "the rest of the album comes with it")
    }

    /// `contentForAlbum` is what the send path builds; a caption set on the
    /// first attachment has to survive it.
    func testAlbumContentKeepsTheCaption() {
        let content = MessageSender.contentForAlbum([
            attachment("a", caption: "trip"),
            attachment("b"),
        ])
        guard case .image(let media) = content else { return XCTFail("expected .image") }
        XCTAssertEqual(media.caption, "trip")
    }
}
