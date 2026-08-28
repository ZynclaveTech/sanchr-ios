import XCTest
import SanchrShared

@testable import Sanchr

/// Media content became a list, Signal-style. The payload sits in the same
/// place in the JSON — only its shape changed — so decoding has to accept both
/// forms or every message already sent, stored, or backed up stops rendering.
final class MediaAttachmentsCodingTests: XCTestCase {

    private func attachment(_ id: String, width: Int? = nil) -> Message.MediaAttachment {
        var a = Message.MediaAttachment(
            url: URL(string: "sanchr-media://\(id)")!,
            encryptionKey: Data([1, 2, 3]),
            encryptionIV: Data([4, 5]),
            mimeType: "image/jpeg",
            sizeBytes: 42,
            thumbnailURL: nil
        )
        a.width = width
        return a
    }

    // MARK: - Legacy compatibility

    /// The shape every message sent before this change is encoded in.
    func testDecodesLegacySingleObjectPayload() throws {
        let legacy = """
        {"image":{"_0":{"url":"sanchr-media://old","encryptionKey":"AQID","encryptionIV":"BAU=",\
        "mimeType":"image/jpeg","sizeBytes":42}}}
        """
        let content = try JSONDecoder().decode(
            Message.MessageContent.self, from: Data(legacy.utf8)
        )
        guard case .image(let media) = content else { return XCTFail("expected .image") }
        XCTAssertEqual(media.count, 1, "a legacy single attachment becomes a list of one")
        XCTAssertEqual(media.first?.url.absoluteString, "sanchr-media://old")
    }

    func testDecodesListPayload() throws {
        let list = """
        {"image":{"_0":[\
        {"url":"sanchr-media://a","encryptionKey":"AQID","encryptionIV":"BAU=","mimeType":"image/jpeg","sizeBytes":1},\
        {"url":"sanchr-media://b","encryptionKey":"AQID","encryptionIV":"BAU=","mimeType":"image/jpeg","sizeBytes":2}\
        ]}}
        """
        let content = try JSONDecoder().decode(
            Message.MessageContent.self, from: Data(list.utf8)
        )
        guard case .image(let media) = content else { return XCTFail("expected .image") }
        XCTAssertEqual(media.items.map(\.url.absoluteString),
                       ["sanchr-media://a", "sanchr-media://b"])
    }

    // MARK: - Round trips

    func testRoundTripsASingleAttachment() throws {
        let original = Message.MessageContent.image(.init(attachment("solo", width: 800)))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.MessageContent.self, from: data)

        guard case .image(let media) = decoded else { return XCTFail("expected .image") }
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media.first?.width, 800, "per-attachment dimensions survive")
    }

    func testRoundTripsAnAlbumPreservingOrder() throws {
        let original = Message.MessageContent.image(
            .init([attachment("1"), attachment("2"), attachment("3")])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.MessageContent.self, from: data)

        guard case .image(let media) = decoded else { return XCTFail("expected .image") }
        // `sanchr-media://1` puts the id in the host, not a path component.
        XCTAssertEqual(media.items.map(\.url.absoluteString),
                       ["sanchr-media://1", "sanchr-media://2", "sanchr-media://3"],
                       "album order is the order the sender arranged")
    }

    /// Always writes the list form, so the wire shape is stable from here.
    func testEncodesAsAList() throws {
        let data = try JSONEncoder().encode(
            Message.MessageContent.image(.init(attachment("x")))
        )
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"_0\":["), "payload must encode as an array: \(json)")
    }

    /// Every media case shares the payload type, so all four must behave alike.
    func testAllMediaCasesUseTheSameShape() throws {
        let cases: [Message.MessageContent] = [
            .image(.init(attachment("i"))),
            .video(.init(attachment("v"))),
            .audio(.init(attachment("a"))),
            .document(.init(attachment("d"))),
        ]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Message.MessageContent.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    /// A malformed payload from a peer must throw, not crash.
    func testMalformedPayloadThrows() {
        let bad = #"{"image":{"_0":"not-an-attachment"}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(Message.MessageContent.self, from: Data(bad.utf8))
        )
    }

    func testNonMediaCasesAreUnaffected() throws {
        for original: Message.MessageContent in [
            .text("hello"),
            .location(latitude: 1.5, longitude: -2.5),
            .contact(name: "Ada", phoneNumber: "+100"),
        ] {
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(
                try JSONDecoder().decode(Message.MessageContent.self, from: data), original
            )
        }
    }
}
