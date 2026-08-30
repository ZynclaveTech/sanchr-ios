import Foundation
import XCTest

@testable import Sanchr

/// What the gallery draws over a video page.
///
/// `AVPlayerViewController` brings a full set of controls of its own — close,
/// AirPlay, volume, scrub — across the top and bottom of the page. Anything the
/// gallery adds there competes with them, so it has to earn its place.
final class VideoChromeLayoutTests: XCTestCase {

    private var gallerySource: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift"
                    ),
                encoding: .utf8
            )
        }
    }

    /// The close button is the player's. Two of them, stacked, was the first
    /// version of this bug.
    func testNoSecondCloseButtonOnAVideo() throws {
        XCTAssertTrue(
            try gallerySource.contains("if !currentPageIsVideo {"),
            "the gallery must not draw its own close button over the player's"
        )
    }

    /// The timestamp is the player's neighbour, not its own toolbar. Together
    /// with the actions button it formed a second row of controls floating
    /// under the player's, which is what looked wrong.
    func testNoTimestampPillOnAVideo() throws {
        let source = try gallerySource
        XCTAssertTrue(
            source.contains("if !currentPageIsVideo,\n                        presentation.items.indices.contains(currentIndex)"),
            "the timestamp pill must be suppressed on video pages"
        )
    }

    /// The actions stay: Save to Photos, Share and Copy exist nowhere else in
    /// the app, so dropping the whole row would remove them for video.
    func testTheActionsMenuSurvives() throws {
        let source = try gallerySource
        for action in ["Save to Photos", "Share", "Copy"] {
            XCTAssertTrue(
                source.contains(action),
                "\(action) is only reachable from here and must not be dropped"
            )
        }
    }

    /// Images are untouched: they have no controls of their own, so the
    /// gallery's chrome is the only chrome they get.
    func testAnImagePageKeepsItsFullChrome() throws {
        let source = try gallerySource
        XCTAssertTrue(
            source.contains("currentPageIsVideo ? 104 : 50"),
            "an image page should keep its original layout, not inherit the video inset"
        )
    }
}
