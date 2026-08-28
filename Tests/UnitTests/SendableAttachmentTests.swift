import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// What the send path is handed for each staged item.
///
/// The upload reads `attachment.url` directly, so this is the single most
/// consequential field on the whole struct: pointing it at a video's poster
/// uploaded a 30 KB still labelled `video/mp4`, never sent the clip, and left
/// the receiver's player trying to play a JPEG.
final class SendableAttachmentTests: XCTestCase {

    private func item(
        video: Bool,
        caption: String = "",
        poster: URL? = URL(fileURLWithPath: "/tmp/poster.jpg")
    ) -> BatchMediaItem {
        BatchMediaItem(
            kind: video ? .video(durationSeconds: 12) : .photo,
            fileURL: URL(fileURLWithPath: video ? "/tmp/clip.mp4" : "/tmp/photo.jpg"),
            sizeBytes: 5_000,
            thumbnail: nil,
            posterURL: video ? poster : nil,
            blurHash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
            pixelWidth: 1920,
            pixelHeight: 1080,
            caption: caption
        )
    }

    /// The regression. `url` must be the clip, never the poster.
    func testVideoUploadsTheClipNotThePoster() {
        let attachment = item(video: true).sendableAttachment()

        XCTAssertEqual(attachment.url.lastPathComponent, "clip.mp4")
        XCTAssertNotEqual(
            attachment.url, attachment.thumbnailURL,
            "url and thumbnailURL must not be the same file"
        )
    }

    /// The poster still has to travel — the bubble reads it for the video
    /// thumbnail and the receiver shows it before downloading.
    func testVideoStillCarriesItsPoster() {
        let attachment = item(video: true).sendableAttachment()
        XCTAssertEqual(attachment.thumbnailURL?.lastPathComponent, "poster.jpg")
    }

    func testPhotoUploadsItsOwnFile() {
        let attachment = item(video: false).sendableAttachment()
        XCTAssertEqual(attachment.url.lastPathComponent, "photo.jpg")
        XCTAssertNil(attachment.thumbnailURL, "a photo needs no poster")
    }

    /// A video with no poster must still send the clip rather than falling
    /// back to something else.
    func testVideoWithoutAPosterStillUploadsTheClip() {
        let attachment = item(video: true, poster: nil).sendableAttachment()
        XCTAssertEqual(attachment.url.lastPathComponent, "clip.mp4")
        XCTAssertNil(attachment.thumbnailURL)
    }

    func testMimeTypeMatchesTheKind() {
        XCTAssertEqual(item(video: true).sendableAttachment().mimeType, "video/mp4")
        XCTAssertEqual(item(video: false).sendableAttachment().mimeType, "image/jpeg")
    }

    /// Dimensions and duration ride along, or the receiver sizes the bubble
    /// from a fallback guess.
    func testMetadataIsCarried() {
        let attachment = item(video: true).sendableAttachment()
        XCTAssertEqual(attachment.width, 1920)
        XCTAssertEqual(attachment.height, 1080)
        XCTAssertEqual(attachment.durationSeconds, 12)
        XCTAssertNotNil(attachment.blurHash)
    }

    func testCaptionIsCarriedWhenPresent() {
        XCTAssertEqual(item(video: false, caption: "at the beach").sendableAttachment().caption,
                       "at the beach")
    }

    /// A blank caption must not become an empty string on the wire, which the
    /// bubble would then reserve space for.
    func testBlankCaptionIsOmitted() {
        XCTAssertNil(item(video: false, caption: "   ").sendableAttachment().caption)
    }
}
