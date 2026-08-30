import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Save, share and copy for media, reachable from the message rather than only
/// from inside the viewer.
final class MediaContextActionsTests: XCTestCase {

    private func media(mime: String, viewOnce: Bool? = nil, count: Int = 1) -> Message.MediaAttachments {
        Message.MediaAttachments((0..<count).map { index in
            var a = Message.MediaAttachment(
                url: URL(string: "sanchr-media://m\(index)")!,
                encryptionKey: Data(), encryptionIV: Data(),
                mimeType: mime, sizeBytes: 1, thumbnailURL: nil
            )
            a.isViewOnce = viewOnce
            return a
        })
    }

    // MARK: - What counts as saveable

    func testPhotosAndVideosAreSaveable() {
        XCTAssertTrue(Message.MessageContent.image(media(mime: "image/jpeg")).isSaveableMedia)
        XCTAssertTrue(Message.MessageContent.video(media(mime: "video/mp4")).isSaveableMedia)
        XCTAssertTrue(Message.MessageContent.image(media(mime: "image/gif")).isSaveableMedia)
    }

    /// An album is saveable too — it is still photos.
    func testAnAlbumIsSaveable() {
        XCTAssertTrue(Message.MessageContent.image(media(mime: "image/jpeg", count: 4)).isSaveableMedia)
    }

    /// Photos cannot store a PDF or a voice note, so offering to save one
    /// would produce a failure nobody can act on.
    func testNonPhotoContentIsNotSaveable() {
        let cases: [Message.MessageContent] = [
            .text("hello"),
            .audio(media(mime: "audio/mp4")),
            .document(media(mime: "application/pdf")),
            .location(latitude: 1, longitude: 2),
            .contact(name: "A", phoneNumber: "+1"),
        ]
        for content in cases {
            XCTAssertFalse(content.isSaveableMedia, "\(content) should not offer Save to Photos")
        }
    }

    /// The one that matters. View-once media is seen once and gone; a Save
    /// button would be a hole straight through the feature.
    func testViewOnceMediaIsNeverSaveable() {
        XCTAssertFalse(
            Message.MessageContent.image(media(mime: "image/jpeg", viewOnce: true)).isSaveableMedia
        )
        XCTAssertFalse(
            Message.MessageContent.video(media(mime: "video/mp4", viewOnce: true)).isSaveableMedia
        )
    }

    /// An empty attachment list is not media, whatever the case says.
    func testEmptyMediaIsNotSaveable() {
        XCTAssertFalse(Message.MessageContent.image(Message.MediaAttachments([])).isSaveableMedia)
    }

    // MARK: - Which attachment gets acted on

    func testTheFirstAttachmentIsTheOneActedOn() {
        let content = Message.MessageContent.image(media(mime: "image/jpeg", count: 3))
        XCTAssertEqual(content.firstAttachment?.url.host, "m0")
    }

    func testContentWithoutAttachmentsResolvesToNothing() {
        XCTAssertNil(Message.MessageContent.text("hi").firstAttachment)
        XCTAssertNil(Message.MessageContent.location(latitude: 1, longitude: 2).firstAttachment)
    }

    // MARK: - The viewer no longer competes with the player

    func testTheGalleryDrawsNothingOverAVideo() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift"
                ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("if chromeVisible, !currentPageIsVideo {"),
            "the player owns a video page; the gallery must not overlay it"
        )
    }
}
