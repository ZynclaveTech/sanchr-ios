import Foundation
import XCTest

@testable import Sanchr

/// What happens to the preview when a second video is chosen.
///
/// The first clip filled the screen and every one after it letterboxed. Two
/// causes, and this covers both: the aspect ratio was computed once from
/// `onAppear` and never cleared, and the player from the previous preview was
/// never released — iOS allows only a few concurrent video decode pipelines,
/// so a leaked one degrades whatever comes next.
final class MediaCaptionLifecycleTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var caption: String {
        get throws { try source("Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift") }
    }

    // MARK: - Identity

    func testTwoVideosAreDifferentMedia() {
        let first = MediaCaptionView.Preview.video(URL(fileURLWithPath: "/tmp/a.mp4"))
        let second = MediaCaptionView.Preview.video(URL(fileURLWithPath: "/tmp/b.mp4"))
        XCTAssertNotEqual(first.identity, second.identity)
    }

    func testTheSameVideoIsTheSameMedia() {
        let url = URL(fileURLWithPath: "/tmp/a.mp4")
        XCTAssertEqual(
            MediaCaptionView.Preview.video(url).identity,
            MediaCaptionView.Preview.video(url).identity
        )
    }

    func testAnImageAndAVideoAreNeverConfused() {
        let image = MediaCaptionView.Preview.image(Data(repeating: 0, count: 8))
        let video = MediaCaptionView.Preview.video(URL(fileURLWithPath: "/tmp/a.mp4"))
        XCTAssertNotEqual(image.identity, video.identity)
    }

    // MARK: - Lifecycle

    /// From `onAppear` this ran once, so a second clip reused whatever the
    /// first left behind.
    func testThePlayerIsKeyedToTheMediaRatherThanToAppearing() throws {
        let body = code(try caption)
        XCTAssertTrue(body.contains(".task(id: preview.identity)"))
        XCTAssertFalse(
            body.contains("player = AVPlayer(url: url)\n                player?.play()"),
            "building the player in onAppear is what made it a once-only job"
        )
    }

    /// Cleared before the new value is read, not after — a stale ratio applied
    /// for the frames in between is the whole visible bug.
    func testTheStaleAspectRatioIsClearedFirst() throws {
        let body = code(try caption)
        let clear = try XCTUnwrap(body.range(of: "videoAspectRatio = nil"))
        let read = try XCTUnwrap(body.range(of: "videoAspectRatio = await MediaAspectFill.aspectRatio"))
        XCTAssertTrue(clear.lowerBound < read.lowerBound)
    }

    /// iOS allows only a few concurrent video decode pipelines, so a preview
    /// that is dismissed while still holding one degrades the next.
    func testThePlayerIsReleasedWhenThePreviewGoes() throws {
        let body = code(try caption)
        XCTAssertTrue(body.contains(".onDisappear {"))
        let disappear = try XCTUnwrap(body.range(of: ".onDisappear {"))
        let after = String(body[disappear.lowerBound...].prefix(200))
        XCTAssertTrue(after.contains("player = nil"))
    }
}
