import Foundation
import XCTest
import SanchrShared

/// The cache is a directory of `<messageId>.<ext>` files, so a write and the
/// read that follows it must agree on `<ext>`. They did not, and the failure
/// mode was silent: the file was written, never found, and never reclaimed.
final class MediaCacheFileTests: XCTestCase {

    /// Every mime type the app actually attaches to an outgoing message.
    /// `image/gif` and `audio/mp4` are the two that were missing from the
    /// writer's table and mapped to `bin` while every reader looked for `jpg`.
    private let sentMimeTypes = [
        "image/jpeg", "image/png", "image/gif",
        "video/mp4", "audio/mp4",
    ]

    func testEverySentMimeTypeHasItsOwnExtension() {
        var seen: [String: String] = [:]
        for mime in sentMimeTypes {
            let ext = MediaCacheFile.fileExtension(for: mime)
            XCTAssertNotEqual(ext, "bin", "\(mime) falls through to the generic suffix")
            if let other = seen[ext] {
                XCTFail("\(mime) and \(other) both map to .\(ext); cache entries would collide")
            }
            seen[ext] = mime
        }
    }

    /// The regression that motivated the shared mapping.
    func testGifAndVoiceNotesAreNotWrittenAsBin() {
        XCTAssertEqual(MediaCacheFile.fileExtension(for: "image/gif"), "gif")
        XCTAssertEqual(MediaCacheFile.fileExtension(for: "audio/mp4"), "m4a")
    }

    /// Case is not normalised anywhere on the way in, and a mime type that
    /// arrives capitalised must not land in a different file from the same
    /// type in lower case.
    func testMatchingIsCaseInsensitive() {
        for mime in sentMimeTypes {
            XCTAssertEqual(
                MediaCacheFile.fileExtension(for: mime.uppercased()),
                MediaCacheFile.fileExtension(for: mime),
                "\(mime) maps differently when capitalised"
            )
        }
    }

    /// An unrecognised type still has to round-trip. Falling back per family
    /// keeps an unknown video from sharing a filename with an unknown image.
    func testUnknownTypesFallBackByFamily() {
        XCTAssertEqual(MediaCacheFile.fileExtension(for: "image/avif"), "img")
        XCTAssertEqual(MediaCacheFile.fileExtension(for: "video/x-matroska"), "vid")
        XCTAssertEqual(MediaCacheFile.fileExtension(for: "audio/ogg"), "aud")
        XCTAssertEqual(MediaCacheFile.fileExtension(for: "application/zip"), "bin")
    }

    func testFileNameCombinesIdAndExtension() {
        XCTAssertEqual(
            MediaCacheFile.fileName(messageId: "abc123", mimeType: "image/png"),
            "abc123.png"
        )
    }

    /// Album tiles share one message id. Without the index they would all
    /// resolve to a single cache entry and every tile would render the same
    /// photo.
    func testAlbumTilesGetDistinctNames() {
        let names = (0..<4).map {
            MediaCacheFile.fileName(messageId: "msg", index: $0, mimeType: "image/jpeg")
        }
        XCTAssertEqual(Set(names).count, 4, "tiles collide on one cache entry")
        XCTAssertEqual(names[0], "msg#0.jpg")
    }

    /// A tile name must not be confusable with the whole-message name, or a
    /// single-attachment message and the first tile of an album would share
    /// an entry.
    func testTileNameDiffersFromTheMessageName() {
        XCTAssertNotEqual(
            MediaCacheFile.fileName(messageId: "msg", index: 0, mimeType: "image/jpeg"),
            MediaCacheFile.fileName(messageId: "msg", mimeType: "image/jpeg")
        )
    }
}
