import XCTest
import SanchrShared

final class MediaAttachmentViewOnceCodableTests: XCTestCase {

    func test_encodeAndDecode_isViewOnceTrue_roundTrips() throws {
        let attachment = Message.MediaAttachment(
            url: URL(string: "sanchr-media://abc")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100,
            isViewOnce: true
        )

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(Message.MediaAttachment.self, from: encoded)

        XCTAssertEqual(decoded.isViewOnce, true)
    }

    func test_decodeLegacyJSONWithoutKey_returnsNil() throws {
        let legacyJSON = """
        {
            "url": "sanchr-media://abc",
            "encryptionKey": "AQ==",
            "encryptionIV": "Ag==",
            "mimeType": "image/jpeg",
            "sizeBytes": 100
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Message.MediaAttachment.self, from: legacyJSON)

        XCTAssertNil(decoded.isViewOnce)
    }

    func test_omitsKeyWhenNil() throws {
        let attachment = Message.MediaAttachment(
            url: URL(string: "sanchr-media://abc")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100,
            isViewOnce: nil
        )

        let encoded = try JSONEncoder().encode(attachment)
        let json = String(data: encoded, encoding: .utf8) ?? ""

        // Default JSONEncoder skips nil optionals — verify the key
        // doesn't leak into the wire format.
        XCTAssertFalse(json.contains("isViewOnce"))
    }
}
