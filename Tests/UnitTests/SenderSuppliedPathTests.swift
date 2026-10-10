import XCTest
import SanchrShared
@testable import Sanchr

/// A message id and a filename are someone else's strings. Neither may choose
/// where a file goes, and a payload may not speak as the app or point at a
/// file already on this device.
final class SenderSuppliedPathTests: XCTestCase {

    private let hostile = [
        "../../Library/Preferences/x", "/etc/hosts", "a/b", "..", ".", "a\\b", "a\u{0}b",
        String(repeating: "x", count: 500), "",
    ]

    // MARK: - Message ids

    /// Unchanged, so files cached before this existed are still found.
    func testIdsBothAppsProduceKeepTheirNames() {
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        XCTAssertEqual(MediaCacheFile.safeId(uuid), uuid)
        XCTAssertEqual(MediaCacheFile.safeId("\(uuid)#3"), "\(uuid)#3")
        XCTAssertEqual(MediaCacheFile.fileName(messageId: "msg_1-a", mimeType: "image/jpeg"), "msg_1-a.jpg")
    }

    func testAHostileIdCannotLeaveTheCacheDirectory() {
        let cache = URL(fileURLWithPath: "/cache/MediaMessages", isDirectory: true)
        for id in hostile {
            let name = MediaCacheFile.fileName(messageId: id, mimeType: "image/jpeg")
            XCTAssertFalse(name.contains("/"), id)
            XCTAssertFalse(name.hasPrefix("."), id)
            let resolved = cache.appendingPathComponent(name).standardizedFileURL
            XCTAssertEqual(resolved.deletingLastPathComponent().path, cache.path, id)
        }
    }

    /// A message's tiles are found by its prefix when it is deleted, so the
    /// tile suffix has to survive whatever happens to the id in front of it.
    func testTilesOfAHostileIdStillShareItsPrefix() {
        let base = MediaCacheFile.safeId("../evil")
        XCTAssertEqual(MediaCacheFile.safeId("../evil#0"), base + "#0")
        XCTAssertEqual(MediaCacheFile.safeId("../evil#12"), base + "#12")
        XCTAssertNotEqual(MediaCacheFile.safeId("../other"), base)
    }

    func testAMalformedPayloadIdFallsBackToTheEnvelopes() {
        for id in hostile + ["m1#0"] {
            XCTAssertEqual(
                MessageRepositoryImpl.canonicalSealedMessageId(sealedEnvelopeId: "envelope-1", innerPayloadMessageId: id),
                "envelope-1",
                id
            )
        }
        XCTAssertEqual(
            MessageRepositoryImpl.canonicalSealedMessageId(sealedEnvelopeId: "envelope-1", innerPayloadMessageId: "local-1"),
            "local-1"
        )
    }

    // MARK: - Filenames

    func testAnOrdinaryFilenameIsKept() {
        XCTAssertEqual(MediaCacheFile.safeDisplayName("report.pdf"), "report.pdf")
        XCTAssertEqual(MediaCacheFile.safeDisplayName("Q3 results (final).xlsx"), "Q3 results (final).xlsx")
    }

    func testAFilenameIsOnlyEverItsLastComponent() {
        XCTAssertEqual(MediaCacheFile.safeDisplayName("../../Library/x.pdf"), "x.pdf")
        XCTAssertEqual(MediaCacheFile.safeDisplayName("/etc/hosts"), "hosts")
        XCTAssertEqual(MediaCacheFile.safeDisplayName("C:\\Users\\a\\x.pdf"), "x.pdf")
    }

    func testAFilenameWithNothingUsableInItIsNoFilename() {
        for name in ["", ".", "..", "/", "../..", "   ", "\u{0}"] {
            XCTAssertNil(MediaCacheFile.safeDisplayName(name), name)
        }
        XCTAssertNil(MediaCacheFile.safeDisplayName(nil))
    }

    // MARK: - Payloads

    private func attachment(_ url: String) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: url)!, encryptionKey: Data(), encryptionIV: Data(), mimeType: "image/jpeg", sizeBytes: 0
        )
    }

    func testUploadedMediaIsAccepted() {
        let content = Message.MessageContent.image(.init(attachment("sanchr-media://abc")))
        XCTAssertEqual(MessageRepositoryImpl.acceptedFromWire(content), content)
        XCTAssertEqual(MessageRepositoryImpl.acceptedFromWire(.text("hi")), .text("hi"))
    }

    /// `file://` means "already on this device", and every viewer opens it.
    func testAnAttachmentPointingAtALocalFileIsNotAccepted() {
        let local = Message.MessageContent.document(.init(attachment("file:///var/mobile/x.sqlite")))
        XCTAssertEqual(MessageRepositoryImpl.acceptedFromWire(local), .text(MessageRepositoryImpl.unsupportedMessageNotice))
        let mixed = Message.MessageContent.image(.init([attachment("sanchr-media://abc"), attachment("file:///x")]))
        XCTAssertEqual(MessageRepositoryImpl.acceptedFromWire(mixed), .text(MessageRepositoryImpl.unsupportedMessageNotice))
    }

    /// System notes are the app's own voice — "safety number changed".
    func testAPayloadCannotSpeakAsTheApp() {
        XCTAssertEqual(
            MessageRepositoryImpl.acceptedFromWire(.system(.identityKeyChanged)),
            .text(MessageRepositoryImpl.unsupportedMessageNotice)
        )
    }
}
